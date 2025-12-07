/*
 * Copyright (c) 2023-2025, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-FileCopyrightText: Copyright (c) 2023-2025, NVIDIA CORPORATION.
 * SPDX-License-Identifier: Apache-2.0
 */

//////////////////////////////////////////////////////////////////////////
/*
    GLTF Renderer with Ray Tracing and Rasterization Support

    This renderer demonstrates advanced real-time rendering of GLTF scenes 
    using both ray tracing and rasterization pipelines. Key features include:
    
    - Dual rendering modes: path tracing and traditional rasterization
    - PBR (Physically Based Rendering) material system
    - HDR environment mapping with prefiltered importance sampling
    - Procedural sky simulation
    - Animation support with skeletal and keyframe animations
    - Progressive rendering for path tracing
    - GLTF 2.0 specification compliance with extensions
    - Interactive ray picking for scene manipulation
    - UI-driven scene editing capabilities
    
    The implementation uses Vulkan with ray tracing extensions and
    employs a modular architecture to handle the full rendering pipeline
    from scene loading to final display, with careful memory management
    and asynchronous command processing for optimal performance.
*/
//////////////////////////////////////////////////////////////////////////

#define VMA_IMPLEMENTATION
#define VMA_LEAK_LOG_FORMAT(format, ...)                                                                               \
  {                                                                                                                    \
    printf((format), __VA_ARGS__);                                                                                     \
    printf("\n");                                                                                                      \
  }
#define IMGUI_DEFINE_MATH_OPERATORS

#include <thread>
#include <ctime>
#include <filesystem>
#include <vulkan/vulkan_core.h>
#include <glm/glm.hpp>
#include <fmt/format.h>

#include "GLFW/glfw3.h"
#undef APIENTRY

// Shader Input/Output
#include "shaders/shaderio.h"  // Shared between host and device

// Pre-compiled shaders
#include "_autogen/tonemapper.slang.h"
#include "_autogen/hdr_dome.slang.h"
#include "_autogen/hdr_integrate_brdf.slang.h"
#include "_autogen/hdr_prefilter_diffuse.slang.h"
#include "_autogen/hdr_prefilter_glossy.slang.h"

//
#include <nvaftermath/aftermath.hpp>
#include <nvapp/elem_dbgprintf.hpp>
#include <nvgui/axis.hpp>
#include <nvgui/file_dialog.hpp>
#include <nvgui/tonemapper.hpp>
#include <nvutils/profiler.hpp>
#include <nvutils/timers.hpp>
#include <nvvk/check_error.hpp>
#include <nvvk/commands.hpp>
#include <nvvk/debug_util.hpp>
#include <nvvk/formats.hpp>
#include <nvvk/helpers.hpp>
#include <nvvk/mipmaps.hpp>
#include <nvvkgltf/camera_utils.hpp>

#include "create_tangent.hpp"
#include "renderer.hpp"
#include "ui_collapsing_header_manager.h"
#include "ui_mouse_state.hpp"
#include "utils.hpp"
#include "tinyobjloader/tiny_obj_loader.h"
#include "nvvkgltf/converter.hpp"
#include "nvvkgltf/tinygltf_utils.hpp"

// For reading image dimensions
#include "stb/stb_image.h"

extern nvutils::ProfilerManager g_profilerManager;  // #PROFILER

// The constructor registers the parameters that can be set from the command line
GltfRenderer::GltfRenderer(nvutils::ParameterRegistry* paramReg)
{
  // All parameters that can be set from the command line
  paramReg->add({"envSystem", "Environment: [Sky:0, HDR:1]"}, (int*)&m_resources.settings.envSystem);
  paramReg->add({"renderSystem", "Renderer [Path tracer:0, Rasterizer:1]"}, (int*)&m_resources.settings.renderSystem);
  paramReg->add({"showAxis", "Show Axis"}, &m_resources.settings.showAxis);
  paramReg->add({"hdrEnvIntensity", "HDR Environment Intensity"}, &m_resources.settings.hdrEnvIntensity);
  paramReg->add({"hdrEnvRotation", "HDR Environment Rotation"}, &m_resources.settings.hdrEnvRotation);
  paramReg->add({"hdrBlur", "HDR Environment Blur"}, &m_resources.settings.hdrBlur);
  paramReg->addVector({"silhouetteColor", "Color of the silhouette"}, &m_resources.settings.silhouetteColor);
  paramReg->add({"debugMethod", "Debug Method"}, (int*)&m_resources.settings.debugMethod);
  paramReg->add({"useSolidBackground", "Use solid color background"}, &m_resources.settings.useSolidBackground, true);
  paramReg->addVector({"solidBackgroundColor", "Solid Background Color"}, &m_resources.settings.solidBackgroundColor);
  paramReg->add({"maxFrames", "Maximum number of iterations"}, &m_resources.settings.maxFrames);

  paramReg->add({"tmMethod", "Tonemapper method: [Filmic:0, Uncharted:1, Clip:2, ACES:3, Agx:4, KhronosPBR:5]"},
                &m_resources.tonemapperData.method);
  paramReg->add({"tmExposure", "Tonemapper exposure"}, &m_resources.tonemapperData.exposure);
  paramReg->add({"tmGamma", "Tonemapper brightness"}, &m_resources.tonemapperData.brightness);
  paramReg->add({"tmContrast", "Tonemapper contrast"}, &m_resources.tonemapperData.contrast);
  paramReg->add({"tmSaturation", "Tonemapper saturation"}, &m_resources.tonemapperData.saturation);
  paramReg->add({"tmWhitePoint", "Tonemapper vignette"}, &m_resources.tonemapperData.vignette);

  // Register PathTracer-specific command line parameters
  m_pathTracer.registerParameters(paramReg);
  m_rasterizer.registerParameters(paramReg);

  // Initialize camera manipulator
  m_cameraManip           = std::make_shared<nvutils::CameraManipulator>();
  m_resources.cameraManip = m_cameraManip;  // Share with resources
}

//--------------------------------------------------------------------------------------------------
// The onAttach method is called when the application is attached to the renderer
void GltfRenderer::onAttach(nvapp::Application* app)
{
  SCOPED_TIMER("GltfRenderer::onAttach");

  m_app                = app;
  m_device             = app->getDevice();
  m_resources.instance = app->getInstance();

  // ===== Memory Allocation & Buffer Management =====
  m_resources.allocator.init({
      .flags            = VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT,
      .physicalDevice   = app->getPhysicalDevice(),
      .device           = app->getDevice(),
      .instance         = app->getInstance(),
      .vulkanApiVersion = VK_API_VERSION_1_4,
  });  // Allocator

  m_transientCmdPool = nvvk::createTransientCommandPool(m_device, app->getQueue(0).familyIndex);
  NVVK_DBG_NAME(m_transientCmdPool);

  // Staging buffer uploader
  m_resources.staging.init(&m_resources.allocator, true);

  m_resources.commandPool = app->getCommandPool();


  // ===== Texture & Image Resources =====
  m_resources.samplerPool.init(m_device);
  VkSampler linearSampler{};
  NVVK_CHECK(m_resources.samplerPool.acquireSampler(linearSampler));
  NVVK_DBG_NAME(linearSampler);

  // IBL environment map
  m_resources.hdrIbl.init(&m_resources.allocator, &m_resources.samplerPool);
  m_resources.hdrDome.init(&m_resources.allocator, &m_resources.samplerPool, m_app->getQueue(0));

  // G-Buffer
  m_resources.gBuffers.init({.allocator = &m_resources.allocator,
                             .colorFormats =
                                 {
                                     VK_FORMAT_R8G8B8A8_UNORM,       // Tonemapped
                                     VK_FORMAT_R32G32B32A32_SFLOAT,  // Rendered image
                                     VK_FORMAT_R8_UNORM,             // Selection (Silhouette)
                                 },
                             .depthFormat    = nvvk::findDepthFormat(app->getPhysicalDevice()),
                             .imageSampler   = linearSampler,
                             .descriptorPool = m_app->getTextureDescriptorPool()});
  {
    VkCommandBuffer cmd{};
    nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);
    m_resources.gBuffers.update(cmd, {100, 100});
    nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);
  }

  // ===== Rendering Utilities =====

  // Ray picker
  m_rayPicker.init(&m_resources.allocator);

  // Tonemapper
  m_resources.tonemapper.init(&m_resources.allocator, tonemapper_slang);

  // Silhouette renderer
  m_silhouette.init(m_resources);

  // Convergence analyzer
  m_convergenceAnalyzer.init(m_resources.allocator, m_device, {100, 100});  // Will be resized on first use

  // VNDF analyzer
  m_vndfAnalyzer.init(m_resources.allocator, m_device, {100, 100});  // Will be resized on first use

  // MSX analyzer
  m_msxTestConfig.resolution = {512, 512};
  m_msxTestConfig.samplesPerPixel = 512;
  m_msxAnalyzer.init(m_resources.allocator, m_device, m_msxTestConfig);
  setupMSXAnalyzerCallbacks();

  // ===== Scene & Acceleration Structure =====
  m_resources.sceneVk.init(&m_resources.allocator, &m_resources.samplerPool);
  m_resources.sceneRtx.init(&m_resources.allocator);

  // ===== Profiling & Performance =====
  {
    SCOPED_TIMER("Profiler");
    m_profilerTimeline = g_profilerManager.createTimeline({.name = "Primary Timeline"});
    m_profilerGpuTimer.init(m_profilerTimeline, m_app->getDevice(), m_app->getPhysicalDevice(), m_app->getQueue(0).familyIndex, false);
  }


  // ===== Shader Compilation =====
  {
    SCOPED_TIMER("Shader Slang");
    using namespace slang;
    m_resources.slangCompiler.addSearchPaths(nvsamples::getShaderDirs());
    m_resources.slangCompiler.defaultTarget();
    m_resources.slangCompiler.defaultOptions();
    m_resources.slangCompiler.addOption(
        {CompilerOptionName::DebugInformation, {CompilerOptionValueKind::Int, SLANG_DEBUG_INFO_LEVEL_MAXIMAL}});
    m_resources.slangCompiler.addOption(
        {CompilerOptionName::Optimization, {CompilerOptionValueKind::Int, SLANG_OPTIMIZATION_LEVEL_DEFAULT}});

#if defined(AFTERMATH_AVAILABLE)
    // This aftermath callback is used to report the shader hash (Spirv) to the Aftermath library.
    m_resources.slangCompiler.setCompileCallback([&](const std::filesystem::path& sourceFile, const uint32_t* spirvCode, size_t spirvSize) {
      std::span<const uint32_t> data(spirvCode, spirvSize / sizeof(uint32_t));
      AftermathCrashTracker::getInstance().addShaderBinary(data);
    });
#endif
  }

  // Initialize RMIP builder
  m_rmipBuilder.init(m_resources.allocator, m_transientCmdPool);

  // Initialize AABB computer for displacement mapping
  m_aabbComputer.init(m_device, &m_resources.allocator);

  // ===== Renderer Initialization =====

  // Create resources
  createDescriptorSets();
  createHDR("");  // Dummy HDR
  createResourceBuffers();

  // Initialize the renderers
  m_pathTracer.onAttach(m_resources, &m_profilerGpuTimer);
  m_pathTracer.setProfilerTimeline(m_profilerTimeline);
  m_rasterizer.onAttach(m_resources, &m_profilerGpuTimer);

  m_pathTracer.createPipeline(m_resources);
  m_rasterizer.createPipeline(m_resources);
}

//--------------------------------------------------------------------------------------------------
// Detach the renderers and destroy the resources
void GltfRenderer::onDetach()
{
  vkDeviceWaitIdle(m_device);
  m_pathTracer.onDetach(m_resources);
  m_rasterizer.onDetach(m_resources);
  destroyResources();
}

//--------------------------------------------------------------------------------------------------
// Resize the G-Buffer and the renderers
void GltfRenderer::onResize(VkCommandBuffer cmd, const VkExtent2D& size)
{
  m_resources.gBuffers.update(cmd, size);
  m_pathTracer.onResize(cmd, size, m_resources);
  m_rasterizer.onResize(cmd, size, m_resources);
  m_resources.hdrDome.setOutImage(m_resources.gBuffers.getDescriptorImageInfo(Resources::eImgRendered));

  resetFrame();  // Reset frame to restart the rendering
}

//--------------------------------------------------------------------------------------------------
// Render the UI elements and handle UI-driven scene interactions
// This method is responsible for:
// 1. Rendering the settings panel with renderer selection, environment options, and debug controls
// 2. Displaying the scene graph hierarchy and handling object selection
// 3. Managing variant and animation controls when available in the loaded scene
// 4. Showing scene statistics and performance metrics
// 5. Rendering the viewport with the tonemapped image and optional 3D axis overlay
// 6. Processing changes from UI interactions and triggering re-rendering when needed
// 7. Displaying the busy indicator during asynchronous operations
// The UI layout is organized hierarchically with collapsible sections for better usability
void GltfRenderer::onUIRender()
{
  renderUI();
}


//--------------------------------------------------------------------------------------------------
// Render the scene
void GltfRenderer::onRender(VkCommandBuffer cmd)
{
  NVVK_DBG_SCOPE(cmd);  // <-- Helps to debug in NSight
  m_profilerTimeline->frameAdvance();
  // Don't do anything if the busy window is open
  if(m_busy.isBusy())
  {
    return;
  }

  // Consume the done signal from the busy state, this will remove the Progress Bar from the UI
  if(m_busy.isDone())
  {
    m_busy.consumeDone();
  }

  // Process queued command buffers in FIFO order
  if(processQueuedCommandBuffers())
  {
    return;  // Give back control to the UI
  }

  // Empty scene, clear the G-Buffer
  if(!m_resources.scene.valid())
  {
    clearGbuffer(cmd);
    return;
  }

  // Start the profiler section for the GPU timer
  auto timerSection = m_profilerGpuTimer.cmdFrameSection(cmd, __FUNCTION__);

  // Update the animation
  bool didAnimate = updateAnimation(cmd);

  // Check for changes
  bool changed      = updateSceneChanges(cmd, didAnimate);
  bool frameChanged = updateFrameCounter();  // Check if the frame counter has changed

  if(changed || frameChanged)
  {
    if(m_resources.frameCount == 0)
    {
      m_cpuTimer.reset();
      m_cpuTimePrinted = false;  // Reset print flag when rendering starts
    }

    // Update the scene frame information uniform buffer
    shaderio::SceneFrameInfo finfo{
        .viewMatrix             = m_cameraManip->getViewMatrix(),
        .projInv                = glm::inverse(m_cameraManip->getPerspectiveMatrix()),
        .viewInv                = glm::inverse(m_cameraManip->getViewMatrix()),
        .viewProjMatrix         = m_cameraManip->getPerspectiveMatrix() * m_cameraManip->getViewMatrix(),
        .prevMVP                = m_prevMVP,
        .envRotation            = m_resources.settings.hdrEnvRotation,
        .envBlur                = m_resources.settings.hdrBlur,
        .envIntensity           = m_resources.settings.hdrEnvIntensity,
        .useSolidBackground     = m_resources.settings.useSolidBackground ? 1 : 0,
        .backgroundColor        = m_resources.settings.solidBackgroundColor,
        .environmentType        = (int)m_resources.settings.envSystem,
        .selectedRenderNode     = m_resources.selectedObject,
        .debugMethod            = m_resources.settings.debugMethod,
        .useInfinitePlane       = m_resources.settings.useInfinitePlane ? 1 : 0,
        .infinitePlaneDistance  = m_resources.settings.infinitePlaneDistance,
        .infinitePlaneBaseColor = m_resources.settings.infinitePlaneBaseColor,
        .infinitePlaneMetallic  = m_resources.settings.infinitePlaneMetallic,
        .infinitePlaneRoughness = m_resources.settings.infinitePlaneRoughness,
    };
    // Update the camera information
    m_prevMVP = finfo.viewProjMatrix;

    vkCmdUpdateBuffer(cmd, m_resources.bFrameInfo.buffer, 0, sizeof(shaderio::SceneFrameInfo), &finfo);
    // Update the sky
    m_resources.skyParams.yIsUp = m_cameraManip->getUp().y > 0.5f;
    vkCmdUpdateBuffer(cmd, m_resources.bSkyParams.buffer, 0, sizeof(shaderio::SkyPhysicalParameters), &m_resources.skyParams);
    // Make sure buffer is ready to be used
    nvvk::cmdMemoryBarrier(cmd, VK_PIPELINE_STAGE_2_TRANSFER_BIT, VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT);

    // Switch between renderers based on the current mode
    switch(m_resources.settings.renderSystem)
    {
      case RenderingMode::ePathtracer:
        m_pathTracer.onRender(cmd, m_resources);
        break;
      case RenderingMode::eRasterizer:
        m_rasterizer.onRender(cmd, m_resources);
        break;
    }

    // Update convergence test if active
    updateConvergenceTest(cmd);

    // Update VNDF test if active
    updateVNDFTest(cmd);

    // Update MSX test if active
    updateMSXTest(cmd);
  }
  else
  {
    // Print CPU time only once after render completes
    if(!m_cpuTimePrinted)
    {
      LOGI("Rendering finished: %f ms\n", m_cpuTimer.getMilliseconds());
      m_cpuTimePrinted = true;
    }
  }

  // Apply the post-processing effects
  tonemap(cmd);
  silhouette(cmd);
}


//--------------------------------------------------------------------------------------------------
// Render the UI menu: File, Tools, Renderer
void GltfRenderer::onUIMenu()
{
  renderMenu();
}

//--------------------------------------------------------------------------------------------------
// Called with headless rendering, to save the final image
void GltfRenderer::onLastHeadlessFrame()
{
  m_app->saveImageToFile(m_resources.gBuffers.getColorImage(Resources::eImgTonemapped), m_resources.gBuffers.getSize(),
                         nvutils::getExecutablePath().replace_extension(".jpg").string());
}

//--------------------------------------------------------------------------------------------------
// Load a glTF scene or an HDR file (called from both Load Scene and Load HDR Environment menu items)
void GltfRenderer::onFileDrop(const std::filesystem::path& filename)
{
  vkQueueWaitIdle(m_app->getQueue(0).queue);

  if(nvutils::extensionMatches(filename, ".gltf") || nvutils::extensionMatches(filename, ".glb")
     || nvutils::extensionMatches(filename, ".obj"))
  {
    if(m_busy.isBusy())
      return;

    m_cmdBufferQueue = {};             // Clear the command buffer queue
    m_resources.scene.destroy();       // Destroy the current scene
    m_resources.selectedObject = -1;   // Reset the selected object
    m_uiSceneGraph.setModel(nullptr);  // Reset the UI model
    m_rasterizer.freeRecordCommandBuffer();

    std::thread([=, this]() {
      m_busy.start("Loading");
      m_lastSceneDirectory = filename.parent_path();
      createScene(filename);
      m_busy.stop();
    }).detach();
  }
  else if(nvutils::extensionMatches(filename, ".hdr"))
  {
    m_lastHdrDirectory = filename.parent_path();
    createHDR(filename);
    m_resources.settings.envSystem                 = shaderio::EnvSystem::eHdr;
    m_pathTracer.m_pushConst.fireflyClampThreshold = m_resources.hdrIbl.getIntegral();
  }

  resetFrame();
}

//--------------------------------------------------------------------------------------------------
// Save the scene
bool GltfRenderer::save(const std::filesystem::path& filename)
{
  if(m_resources.scene.valid() && !filename.empty())
  {
    // First, copy the camera
    nvvkgltf::RenderCamera camera;
    m_cameraManip->getLookat(camera.eye, camera.center, camera.up);
    camera.yfov  = glm::radians(m_cameraManip->getFov());
    camera.znear = m_cameraManip->getClipPlanes().x;
    camera.zfar  = m_cameraManip->getClipPlanes().y;
    m_resources.scene.setSceneCamera(camera);

    // Saving the scene
    return m_resources.scene.save(filename);
  }
  return false;
}

//--------------------------------------------------------------------------------------------------
// Apply the tonemapper on the rendered image
void GltfRenderer::tonemap(VkCommandBuffer cmd)
{
  NVVK_DBG_SCOPE(cmd);  // <-- Helps to debug in NSight
  auto timerSection = m_profilerGpuTimer.cmdFrameSection(cmd, __FUNCTION__);

  // When debug method is not none, the tonemapper should do nothing to visualize the data
  shaderio::TonemapperData tonemapperData = m_resources.tonemapperData;
  if(m_resources.settings.debugMethod != shaderio::DebugMethod::eNone)
  {
    tonemapperData.isActive = 0;
  }
  m_resources.tonemapper.runCompute(cmd, m_resources.gBuffers.getSize(), tonemapperData,
                                    m_resources.gBuffers.getDescriptorImageInfo(Resources::eImgRendered),
                                    m_resources.gBuffers.getDescriptorImageInfo(Resources::eImgTonemapped));

  // Memory barrier to ensure compute shader writes are complete before fragment shader reads
  nvvk::cmdMemoryBarrier(cmd, VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT);
}

//--------------------------------------------------------------------------------------------------
// Render the silhouette of the selected object
void GltfRenderer::silhouette(VkCommandBuffer cmd)
{
  // Adding the silhouette pass after all rendering passes
  if(m_resources.selectedObject > -1)
  {
    NVVK_DBG_SCOPE(cmd);  // <-- Helps to debug in NSight
    auto timerSection = m_profilerGpuTimer.cmdFrameSection(cmd, __FUNCTION__);

    std::vector<VkDescriptorImageInfo> imageInfos = {
        m_resources.gBuffers.getDescriptorImageInfo(Resources::eImgSelection),
        m_resources.gBuffers.getDescriptorImageInfo(Resources::eImgTonemapped),
    };
    m_silhouette.dispatch(cmd, m_resources.gBuffers.getSize(), imageInfos);
    nvvk::cmdMemoryBarrier(cmd, VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT);
  }
}


//--------------------------------------------------------------------------------------------------
// Load the scene
void GltfRenderer::createScene(const std::filesystem::path& sceneFilename)
{
  nvutils::ScopedTimer st(__FUNCTION__);
  m_uiSceneGraph.setModel(nullptr);

  if(sceneFilename.empty())
  {
    return;
  }

  std::filesystem::path filename = nvutils::findFile(sceneFilename, nvsamples::getResourcesDirs(), false);
  if(!filename.has_filename())
  {
    LOGW("Cannot find file: %s\n", nvutils::utf8FromPath(sceneFilename).c_str());
    removeFromRecentFiles(filename);
    return;
  }

  // Convert OBJ to glTF
  if(nvutils::extensionMatches(sceneFilename, ".obj"))
  {
    tinyobj::ObjReaderConfig readerConfig;
    readerConfig.mtl_search_path = std::filesystem::path(filename).parent_path().string();
    tinyobj::ObjReader reader;

    bool        result = reader.ParseFromFile(nvutils::utf8FromPath(filename), readerConfig);
    std::string warn   = reader.Warning();
    std::string error  = reader.Error();

    if(result)
    {
      TinyConverter   converter;
      tinygltf::Model model;
      converter.convert(model, reader);
      m_resources.scene.takeModel(std::move(model));
    }
    else
    {
      LOGW("Error loading OBJ: %s\n", error.c_str());
      LOGW("Warning: %s\n", warn.c_str());
      removeFromRecentFiles(filename);
      return;
    }
  }
  else
  {
    LOGI("Loading scene: %s\n", nvutils::utf8FromPath(filename).c_str());
    if(!m_resources.scene.load(filename))  // Loading the scene
    {
      LOGW("Error loading scene: %s\n", nvutils::utf8FromPath(filename).c_str());
      removeFromRecentFiles(filename);
      return;
    }
  }

  // Scene is loaded, we can create the Vulkan scene
  createVulkanScene();

  // UI needs to be updated
  m_uiSceneGraph.setModel(&m_resources.scene.getModel());
  m_uiSceneGraph.setBbox(m_resources.scene.getSceneBounds());
  m_resources.settings.infinitePlaneDistance = m_resources.scene.getSceneBounds().min().y;  // Set the infinite plane distance to the bottom of the scene

  // Set camera from scene
  nvvkgltf::addSceneCamerasToWidget(m_cameraManip, filename, m_resources.scene.getRenderCameras(),
                                    m_resources.scene.getSceneBounds());

  // Default sky parameters
  m_resources.skyParams = {};

  // Need to update (push) all textures
  updateTextures();

  addToRecentFiles(filename);
}

//--------------------------------------------------------------------------------------------------
// Add a glTF file to the existing scene (merge models)
void GltfRenderer::addToScene(const std::filesystem::path& sceneFilename)
{
  nvutils::ScopedTimer st(__FUNCTION__);

  if(sceneFilename.empty() || !m_resources.scene.valid())
  {
    LOGW("Cannot add to scene: no file specified or no existing scene\n");
    return;
  }

  std::filesystem::path filename = nvutils::findFile(sceneFilename, nvsamples::getResourcesDirs(), false);
  if(!filename.has_filename())
  {
    LOGW("Cannot find file: %s\n", nvutils::utf8FromPath(sceneFilename).c_str());
    return;
  }

  // Only support glTF files for adding (not OBJ)
  if(nvutils::extensionMatches(sceneFilename, ".obj"))
  {
    LOGW("OBJ files cannot be added to scene. Please use glTF format.\n");
    return;
  }

  LOGI("Adding to scene: %s\n", nvutils::utf8FromPath(filename).c_str());

  // Load the new model
  tinygltf::Model     newModel;
  tinygltf::TinyGLTF  loader;
  std::string         err, warn;
  bool                result = false;

  if(nvutils::extensionMatches(filename, ".glb"))
  {
    result = loader.LoadBinaryFromFile(&newModel, &err, &warn, nvutils::utf8FromPath(filename));
  }
  else
  {
    result = loader.LoadASCIIFromFile(&newModel, &err, &warn, nvutils::utf8FromPath(filename));
  }

  if(!warn.empty())
    LOGW("Warning loading glTF: %s\n", warn.c_str());
  if(!err.empty())
    LOGE("Error loading glTF: %s\n", err.c_str());
  if(!result)
  {
    LOGE("Failed to load glTF file: %s\n", nvutils::utf8FromPath(filename).c_str());
    return;
  }

  // Get the existing model
  tinygltf::Model& existingModel = m_resources.scene.getModel();

  // Calculate offsets for merging
  int bufferOffset     = static_cast<int>(existingModel.buffers.size());
  int bufferViewOffset = static_cast<int>(existingModel.bufferViews.size());
  int accessorOffset   = static_cast<int>(existingModel.accessors.size());
  int imageOffset      = static_cast<int>(existingModel.images.size());
  int samplerOffset    = static_cast<int>(existingModel.samplers.size());
  int textureOffset    = static_cast<int>(existingModel.textures.size());
  int materialOffset   = static_cast<int>(existingModel.materials.size());
  int meshOffset       = static_cast<int>(existingModel.meshes.size());
  int nodeOffset       = static_cast<int>(existingModel.nodes.size());
  int skinOffset       = static_cast<int>(existingModel.skins.size());
  int cameraOffset     = static_cast<int>(existingModel.cameras.size());

  // Merge buffers
  for(auto& buffer : newModel.buffers)
  {
    existingModel.buffers.push_back(std::move(buffer));
  }

  // Merge buffer views (update buffer indices)
  for(auto& bv : newModel.bufferViews)
  {
    if(bv.buffer >= 0)
      bv.buffer += bufferOffset;
    existingModel.bufferViews.push_back(std::move(bv));
  }

  // Merge accessors (update buffer view indices)
  for(auto& accessor : newModel.accessors)
  {
    if(accessor.bufferView >= 0)
      accessor.bufferView += bufferViewOffset;
    if(accessor.sparse.indices.bufferView >= 0)
      accessor.sparse.indices.bufferView += bufferViewOffset;
    if(accessor.sparse.values.bufferView >= 0)
      accessor.sparse.values.bufferView += bufferViewOffset;
    existingModel.accessors.push_back(std::move(accessor));
  }

  // Merge images
  for(auto& image : newModel.images)
  {
    if(image.bufferView >= 0)
      image.bufferView += bufferViewOffset;
    existingModel.images.push_back(std::move(image));
  }

  // Merge samplers
  for(auto& sampler : newModel.samplers)
  {
    existingModel.samplers.push_back(std::move(sampler));
  }

  // Merge textures (update source and sampler indices)
  for(auto& texture : newModel.textures)
  {
    if(texture.source >= 0)
      texture.source += imageOffset;
    if(texture.sampler >= 0)
      texture.sampler += samplerOffset;
    existingModel.textures.push_back(std::move(texture));
  }

  // Helper to update texture info indices
  auto updateTextureInfo = [textureOffset](tinygltf::TextureInfo& ti) {
    if(ti.index >= 0)
      ti.index += textureOffset;
  };
  auto updateNormalTextureInfo = [textureOffset](tinygltf::NormalTextureInfo& ti) {
    if(ti.index >= 0)
      ti.index += textureOffset;
  };
  auto updateOcclusionTextureInfo = [textureOffset](tinygltf::OcclusionTextureInfo& ti) {
    if(ti.index >= 0)
      ti.index += textureOffset;
  };

  // Merge materials (update texture indices)
  for(auto& mat : newModel.materials)
  {
    updateTextureInfo(mat.pbrMetallicRoughness.baseColorTexture);
    updateTextureInfo(mat.pbrMetallicRoughness.metallicRoughnessTexture);
    updateNormalTextureInfo(mat.normalTexture);
    updateOcclusionTextureInfo(mat.occlusionTexture);
    updateTextureInfo(mat.emissiveTexture);
    existingModel.materials.push_back(std::move(mat));
  }

  // Merge meshes (update accessor and material indices)
  for(auto& mesh : newModel.meshes)
  {
    for(auto& prim : mesh.primitives)
    {
      if(prim.indices >= 0)
        prim.indices += accessorOffset;
      if(prim.material >= 0)
        prim.material += materialOffset;
      for(auto& attr : prim.attributes)
      {
        if(attr.second >= 0)
          attr.second += accessorOffset;
      }
      for(auto& target : prim.targets)
      {
        for(auto& attr : target)
        {
          if(attr.second >= 0)
            attr.second += accessorOffset;
        }
      }
    }
    existingModel.meshes.push_back(std::move(mesh));
  }

  // Merge skins (update accessor and node indices)
  for(auto& skin : newModel.skins)
  {
    if(skin.inverseBindMatrices >= 0)
      skin.inverseBindMatrices += accessorOffset;
    if(skin.skeleton >= 0)
      skin.skeleton += nodeOffset;
    for(auto& joint : skin.joints)
    {
      if(joint >= 0)
        joint += nodeOffset;
    }
    existingModel.skins.push_back(std::move(skin));
  }

  // Merge cameras
  for(auto& camera : newModel.cameras)
  {
    existingModel.cameras.push_back(std::move(camera));
  }

  // Merge nodes (update mesh, skin, camera, and children indices)
  std::vector<int> newRootNodes;
  for(size_t i = 0; i < newModel.nodes.size(); i++)
  {
    auto& node = newModel.nodes[i];
    if(node.mesh >= 0)
      node.mesh += meshOffset;
    if(node.skin >= 0)
      node.skin += skinOffset;
    if(node.camera >= 0)
      node.camera += cameraOffset;
    for(auto& child : node.children)
    {
      if(child >= 0)
        child += nodeOffset;
    }
    existingModel.nodes.push_back(std::move(node));
  }

  // Find root nodes from the new model's default scene
  int newSceneIndex = newModel.defaultScene >= 0 ? newModel.defaultScene : 0;
  if(newSceneIndex < static_cast<int>(newModel.scenes.size()))
  {
    for(int rootNode : newModel.scenes[newSceneIndex].nodes)
    {
      newRootNodes.push_back(rootNode + nodeOffset);
    }
  }

  // Create a wrapper node for the new model to preserve its hierarchy
  // This prevents the new model's nodes from being flattened into the existing scene
  tinygltf::Node wrapperNode;
  wrapperNode.name = sceneFilename.stem().string();  // Use filename as wrapper name
  wrapperNode.children = newRootNodes;               // New model's root nodes become children of wrapper
  int wrapperNodeIndex = static_cast<int>(existingModel.nodes.size());
  existingModel.nodes.push_back(std::move(wrapperNode));

  // Add only the wrapper node to the existing scene (not individual root nodes)
  int existingSceneIndex = existingModel.defaultScene >= 0 ? existingModel.defaultScene : 0;
  if(existingSceneIndex < static_cast<int>(existingModel.scenes.size()))
  {
    existingModel.scenes[existingSceneIndex].nodes.push_back(wrapperNodeIndex);
  }

  // Merge animations (update node and accessor indices)
  for(auto& anim : newModel.animations)
  {
    for(auto& channel : anim.channels)
    {
      if(channel.target_node >= 0)
        channel.target_node += nodeOffset;
    }
    for(auto& sampler : anim.samplers)
    {
      if(sampler.input >= 0)
        sampler.input += accessorOffset;
      if(sampler.output >= 0)
        sampler.output += accessorOffset;
    }
    existingModel.animations.push_back(std::move(anim));
  }

  LOGI("Merged: +%zu nodes, +%zu meshes, +%zu materials\n",
       newModel.nodes.size(), newModel.meshes.size(), newModel.materials.size());

  // Re-parse the scene to update render nodes
  m_resources.scene.setCurrentScene(existingSceneIndex);

  // Destroy existing Vulkan resources and recreate
  // First wait for all queue operations to complete
  vkQueueWaitIdle(m_app->getQueue(0).queue);
  vkDeviceWaitIdle(m_device);

  // Clear the command buffer queue to prevent stale references
  {
    std::lock_guard<std::mutex> lock(m_cmdBufferQueueMutex);
    m_cmdBufferQueue = {};
  }

  // Release any pending staging operations before destroying scene resources
  m_resources.staging.releaseStaging(true);

  // Free rasterizer command buffer that may reference old scene
  m_rasterizer.freeRecordCommandBuffer();

  // Don't call deinit() on sceneVk or sceneRtx - their create functions call destroy() internally
  // Calling deinit() before create() would cause double-free crashes

  // Recreate Vulkan scene (create functions handle their own cleanup via destroy())
  createVulkanScene();

  // Update UI
  m_uiSceneGraph.setModel(&m_resources.scene.getModel());
  m_uiSceneGraph.setBbox(m_resources.scene.getSceneBounds());

  // Update textures
  updateTextures();

  LOGI("Scene updated with added content\n");
}

//--------------------------------------------------------------------------------------------------
// This function creates the Vulkan scene from the glTF model
// It builds the bottom-level and top-level acceleration structure
// The function is called when the scene is loaded
void GltfRenderer::createVulkanScene()
{
  VkBuildAccelerationStructureFlagsKHR flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR
                                               | VK_BUILD_ACCELERATION_STRUCTURE_ALLOW_COMPACTION_BIT_KHR;
  if(m_resources.scene.hasAnimation())
  {
    flags |= VK_BUILD_ACCELERATION_STRUCTURE_ALLOW_UPDATE_BIT_KHR;  // Allow update
  }

  {
    // Create and queue command buffer for scene data upload (vertices, indices, materials, etc.)
    // This work happens asynchronously via the command buffer queue
    VkCommandBuffer cmd{};
    nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);

    m_resources.sceneVk.create(cmd, m_resources.staging, m_resources.scene, false);  // Creating the scene in Vulkan buffers
    m_resources.staging.cmdUploadAppended(cmd);

    // CRITICAL: Execute vertex upload IMMEDIATELY (not queued)
    // The AABB compute shader needs vertex data to be available BEFORE it runs
    nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);
    LOGI("[Renderer] Vertex data uploaded immediately (synchronous)\n");
  }
  // Build RMIPs FIRST, before creating BLAS (needed for displacement info)
  {
    VkCommandBuffer cmd{};
    nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);
    buildDisplacementRMIPs(cmd);
    nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);
  }


  // Prepare displacement information for BLAS creation (AABB geometry)
  std::vector<nvvkgltf::DisplacementInfo> displacementInfo(m_resources.scene.getModel().materials.size());
  for(size_t matIdx = 0; matIdx < m_displacementRMIPs.size() && matIdx < displacementInfo.size(); matIdx++)
  {
    const auto& rmipData = m_displacementRMIPs[matIdx];
    if(rmipData.hasDisplacement)
    {
      displacementInfo[matIdx].hasDisplacement = true;
      displacementInfo[matIdx].minDisplacement = 0.0f;  // Assuming normalized height map
      displacementInfo[matIdx].maxDisplacement = rmipData.displacementFactor;  // Scale factor
    }
  }

  // Create the bottom-level acceleration structure descriptors (no building yet)
  // Use the new overload that supports AABB geometry for displaced primitives
  m_resources.sceneRtx.createBottomLevelAccelerationStructure(m_resources.scene, m_resources.sceneVk, flags, displacementInfo);

  // Compute AABBs for displaced primitives before building BLAS
  {
    const auto& renderPrimitives = m_resources.scene.getRenderPrimitives();
    const auto& vertexBuffers = m_resources.sceneVk.vertexBuffers();
    const auto& indices = m_resources.sceneVk.indices();

    // Check if we have any displaced primitives
    bool hasAnyDisplacement = false;
    for(const auto& info : displacementInfo)
    {
      if(info.hasDisplacement)
      {
        hasAnyDisplacement = true;
        break;
      }
    }

    LOGI("[AABB] hasAnyDisplacement=%d, displacementInfo.size()=%zu, renderPrimitives.size()=%zu\n",
         hasAnyDisplacement, displacementInfo.size(), renderPrimitives.size());
    LOGI("[AABB] vertexBuffers.size()=%zu, indices.size()=%zu\n",
         vertexBuffers.size(), indices.size());

    if(hasAnyDisplacement)
    {
      VkCommandBuffer cmd{};
      nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);

      // For each displaced primitive, compute its AABBs
      VkDeviceSize aabbOffset = 0;
      uint32_t numDisplacedPrims = 0;
      for(uint32_t p_idx = 0; p_idx < renderPrimitives.size(); p_idx++)
      {
        const auto& prim = renderPrimitives[p_idx];

        // Check if this primitive has displacement
        bool hasDisplacement = false;
        nvvkgltf::DisplacementInfo dispInfo;
        if(prim.pPrimitive && prim.pPrimitive->material >= 0 &&
           prim.pPrimitive->material < static_cast<int>(displacementInfo.size()))
        {
          dispInfo = displacementInfo[prim.pPrimitive->material];
          hasDisplacement = dispInfo.hasDisplacement;
          LOGI("[AABB]   Prim %u: material=%d, hasDisp=%d\n", p_idx, prim.pPrimitive->material, hasDisplacement);
        }
        else
        {
          LOGI("[AABB]   Prim %u: NO MATERIAL\n", p_idx);
        }
        if(hasDisplacement)
        {
          // Prepare AABB compute parameters
          AabbComputeParams params;
          params.numTriangles = prim.indexCount / 3;
          params.minDisplacement = dispInfo.minDisplacement;
          params.maxDisplacement = dispInfo.maxDisplacement;
          params.padding = 0;

          // Create sub-buffer view for this primitive's AABBs
          const nvvk::Buffer& aabbBuffer = m_resources.sceneRtx.getAabbBuffer();
          nvvk::Buffer aabbSubBuffer;
          aabbSubBuffer.buffer = aabbBuffer.buffer;
          aabbSubBuffer.address = aabbBuffer.address + aabbOffset;

          LOGI("[AABB]     Computing %u AABBs: minDisp=%.3f, maxDisp=%.3f, buffer addr=0x%llx\n",
               params.numTriangles, params.minDisplacement, params.maxDisplacement, aabbSubBuffer.address);
          LOGI("[AABB]     Vertex buffer addr=0x%llx, Index buffer addr=0x%llx\n",
               vertexBuffers[p_idx].position.address, indices[p_idx].address);
          LOGI("[AABB]     Prim indexCount=%u, vertexCount=%u\n", prim.indexCount, prim.vertexCount);

          // DEBUG: Read back vertex buffer to verify contents
          const nvvk::Buffer& vtxBuf = vertexBuffers[p_idx].position;
          if(vtxBuf.mapping != nullptr)
          {
            glm::vec3* vertices = reinterpret_cast<glm::vec3*>(vtxBuf.mapping);
            LOGI("[AABB]     First 4 vertices from CPU-side mapping:\n");
            uint32_t numVertsToShow = (prim.vertexCount < 4) ? prim.vertexCount : 4;
            for(uint32_t v = 0; v < numVertsToShow; v++)
            {
              LOGI("[AABB]       v[%u] = (%.3f, %.3f, %.3f)\n", v, vertices[v].x, vertices[v].y, vertices[v].z);
            }
          }
          else
          {
            LOGI("[AABB]     WARNING: Vertex buffer not mapped, cannot verify contents!\n");
          }

          // DEBUG: Read back index buffer
          const nvvk::Buffer& idxBuf = indices[p_idx];
          if(idxBuf.mapping != nullptr)
          {
            uint32_t* idxData = reinterpret_cast<uint32_t*>(idxBuf.mapping);
            LOGI("[AABB]     First 6 indices: %u %u %u %u %u %u\n",
                 idxData[0], idxData[1], idxData[2], idxData[3], idxData[4], idxData[5]);
          }

          numDisplacedPrims++;

          // Compute AABBs for this primitive
          m_aabbComputer.computeAABBs(cmd,
                                      vertexBuffers[p_idx].position,
                                      vertexBuffers[p_idx].normal,
                                      indices[p_idx],
                                      aabbSubBuffer,
                                      params);

          aabbOffset += params.numTriangles * sizeof(VkAabbPositionsKHR);
        }
      }
      LOGI("[AABB] Computed for %u primitives\n", numDisplacedPrims);

      // Submit and wait (AABBs must be ready before BLAS build)
      nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);

      // DEBUG: Read back first AABB to verify correctness
      if(numDisplacedPrims > 0)
      {
        const nvvk::Buffer& aabbBuffer = m_resources.sceneRtx.getAabbBuffer();
        if(aabbBuffer.mapping != nullptr)
        {
          struct VkAabbPositionsKHR {
            float minX, minY, minZ, maxX, maxY, maxZ;
          };
          VkAabbPositionsKHR* aabbs = reinterpret_cast<VkAabbPositionsKHR*>(aabbBuffer.mapping);
          LOGI("[AABB] First AABB: min=(%.3f, %.3f, %.3f), max=(%.3f, %.3f, %.3f)\n",
               aabbs[0].minX, aabbs[0].minY, aabbs[0].minZ,
               aabbs[0].maxX, aabbs[0].maxY, aabbs[0].maxZ);
        }
        else
        {
          LOGI("[AABB] WARNING: AABB buffer not mapped!\n");
        }
      }
    }
  }

  // Build the bottom-level acceleration structure
  // Memory-conscious approach: build within a fixed memory budget using multiple command buffers if needed
  // Each build command is queued separately and followed by compaction to optimize memory usage
  {
    bool finished = false;

    // Building BLAS within a memory budget, which could involve multiple calls to cmdBuildBottomLevelAccelerationStructure
    do
    {
      VkCommandBuffer cmd{};
      nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);
      // This won't compact the BLAS, but will create the acceleration structure
      finished = m_resources.sceneRtx.cmdBuildBottomLevelAccelerationStructure(cmd, 512'000'000);
      {
        std::lock_guard<std::mutex> lock(m_cmdBufferQueueMutex);
        m_cmdBufferQueue.push({cmd, true});  // Mark as BLAS build command for immediate compaction
      }

    } while(!finished);

    // Queue TLAS building for after all BLAS work completes
    // TLAS is the top-level structure referencing all bottom-level acceleration structures
    // IMPORTANT: This must be queued and executed AFTER BLAS build completes
    // The queue processing ensures correct ordering: BLAS first, then TLAS
    {
      VkCommandBuffer cmd{};
      nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);
      m_resources.sceneRtx.cmdCreateBuildTopLevelAccelerationStructure(cmd, m_resources.staging, m_resources.scene, displacementInfo);
      m_resources.staging.cmdUploadAppended(cmd);
      {
        std::lock_guard<std::mutex> lock(m_cmdBufferQueueMutex);
        m_cmdBufferQueue.push({cmd, false});  // Not a BLAS build command
      }
      LOGI("[Renderer] TLAS build queued (will execute after BLAS build)\n");
    }

  }

  // Build mapping for faster node lookups
  updateNodeToRenderNodeMap();

  // Initialize QOLDS sampling
  createQoldsBuffers();
}

//--------------------------------------------------------------------------------------------------
// Create and upload QOLDS sampling buffers
void GltfRenderer::createQoldsBuffers()
{
  // Destroy existing QOLDS buffers if they exist (happens when loading a new scene)
  if(m_resources.bQoldsMatrices.buffer != VK_NULL_HANDLE)
  {
    m_resources.allocator.destroyBuffer(m_resources.bQoldsMatrices);
  }
  if(m_resources.bQoldsSeeds.buffer != VK_NULL_HANDLE)
  {
    m_resources.allocator.destroyBuffer(m_resources.bQoldsSeeds);
  }

  // Initialize QOLDS builder
  m_qoldsBuilder = std::make_unique<QOLDSBuilder>();

  // Load irreducible polynomials using proper path resolution
  std::filesystem::path qoldsDataPath = nvutils::findFile("initIrreducibleGF3.dat", nvsamples::getResourcesDirs(), false);
  if(qoldsDataPath.empty())
  {
    // Fallback: try relative to executable
    qoldsDataPath = nvutils::getExecutablePath().parent_path() / "resources" / "initIrreducibleGF3.dat";
  }

  if(!m_qoldsBuilder->loadInitData(qoldsDataPath.string()))
  {
    LOGE("Failed to load QOLDS initialization data from: %s\n", qoldsDataPath.string().c_str());
    return;
  }

  // Build matrices: 47 dimensions, m=5 (243 max points)
  // Note: The initIrreducibleGF3.dat file contains data for 47 dimensions (1-47)
  m_qoldsBuilder->buildMatrices(47, 5);

  // Generate scrambling seeds (use fixed seed for reproducibility, or 0 for random)
  m_qoldsBuilder->generateScrambleSeeds(0);

  // Get data for GPU upload
  const auto& matrices = m_qoldsBuilder->getMatrixData();
  const auto& seeds    = m_qoldsBuilder->getScrambleSeeds();

  // Create matrices buffer
  VkDeviceSize matrixSize = matrices.size() * sizeof(int32_t);
  NVVK_CHECK(m_resources.allocator.createBuffer(m_resources.bQoldsMatrices, matrixSize,
                                                VK_BUFFER_USAGE_2_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_2_TRANSFER_DST_BIT,
                                                VMA_MEMORY_USAGE_GPU_ONLY));
  NVVK_DBG_NAME(m_resources.bQoldsMatrices.buffer);

  // Create seeds buffer
  VkDeviceSize seedsSize = seeds.size() * sizeof(uint32_t);
  NVVK_CHECK(m_resources.allocator.createBuffer(m_resources.bQoldsSeeds, seedsSize,
                                                VK_BUFFER_USAGE_2_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_2_TRANSFER_DST_BIT,
                                                VMA_MEMORY_USAGE_GPU_ONLY));
  NVVK_DBG_NAME(m_resources.bQoldsSeeds.buffer);

  // Upload data using staging buffer
  VkCommandBuffer cmd{};
  nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);

  m_resources.staging.appendBuffer(m_resources.bQoldsMatrices, 0, matrixSize, matrices.data());
  m_resources.staging.appendBuffer(m_resources.bQoldsSeeds, 0, seedsSize, seeds.data());
  m_resources.staging.cmdUploadAppended(cmd);

  nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);

  LOGI("QOLDS buffers created: %d dimensions, %d max points\n", m_qoldsBuilder->getDimensions(),
       m_qoldsBuilder->getMaxPoints());
}

//--------------------------------------------------------------------------------------------------
// Clear the G-Buffer
void GltfRenderer::clearGbuffer(VkCommandBuffer cmd)
{
  const VkClearColorValue clearValue = {{0.17f, 0.21f, 0.25f, 1.f}};
  VkImageSubresourceRange range      = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1};
  vkCmdClearColorImage(cmd, m_resources.gBuffers.getColorImage(Resources::eImgTonemapped), VK_IMAGE_LAYOUT_GENERAL,
                       &clearValue, 1, &range);

  // Ensure the clear operation completes before any subsequent reads from this image
  nvvk::cmdMemoryBarrier(cmd, VK_PIPELINE_STAGE_2_CLEAR_BIT, VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
                         VK_ACCESS_2_TRANSFER_WRITE_BIT, VK_ACCESS_2_SHADER_READ_BIT);
}

//--------------------------------------------------------------------------------------------------
// Create the uniform buffers for frame-specific data
// This function initializes two key uniform buffers:
// 1. bFrameInfo - Contains per-frame camera matrices, environment settings, and debug information
//    Updated each frame with current view/projection matrices and rendering settings
// 2. bSkyParams - Contains physical parameters for the procedural sky simulation
//    Used when environment type is set to Sky instead of HDR
//
void GltfRenderer::createResourceBuffers()
{
  // Create the buffer of the current camera transformation, changing at each frame
  NVVK_CHECK(m_resources.allocator.createBuffer(m_resources.bFrameInfo, sizeof(shaderio::SceneFrameInfo),
                                                VK_BUFFER_USAGE_2_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_2_TRANSFER_DST_BIT,
                                                VMA_MEMORY_USAGE_CPU_TO_GPU));
  NVVK_DBG_NAME(m_resources.bFrameInfo.buffer);
  // Create the buffer of sky parameters, updated at each frame
  NVVK_CHECK(m_resources.allocator.createBuffer(m_resources.bSkyParams, sizeof(shaderio::SkyPhysicalParameters),
                                                VK_BUFFER_USAGE_2_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_2_TRANSFER_DST_BIT,
                                                VMA_MEMORY_USAGE_CPU_TO_GPU));
  NVVK_DBG_NAME(m_resources.bSkyParams.buffer);
}

//--------------------------------------------------------------------------------------------------
// Create the descriptor set and the pipelines
// There are two descriptor: one for the textures (set) and one (push) for the top level acceleration structure and the default output image
// There are two pipelines: one for the PathTracer and one for the Rasterizer
// The descriptor set is shared between the two pipelines
void GltfRenderer::createDescriptorSets()
{
  // Reserve 2050 textures (2000 for scene textures + 50 for other purposes like the environment)
  VkPhysicalDeviceProperties deviceProperties;
  vkGetPhysicalDeviceProperties(m_app->getPhysicalDevice(), &deviceProperties);
  uint32_t maxTextures = std::min(10000U, deviceProperties.limits.maxDescriptorSetSampledImages - 1);

  // 0: Descriptor SET: all textures of the scene
  m_resources.descriptorBinding[0].addBinding(shaderio::BindingPoints::eTextures, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                                              maxTextures, VK_SHADER_STAGE_ALL, nullptr,
                                              VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT | VK_DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT
                                                  | VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT);
  // The 2 textures are for the HDR environment map: one is the pre-integrated BRDF LUT, the other is the HDR image
  m_resources.descriptorBinding[0].addBinding(shaderio::BindingPoints::eTexturesHdr,
                                              VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2, VK_SHADER_STAGE_ALL, nullptr,
                                              VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT | VK_DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT
                                                  | VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT);
  // The 2 other HDR textures with cube maps: pre-convoluted diffuse and glossy maps
  m_resources.descriptorBinding[0].addBinding(shaderio::BindingPoints::eTexturesCube,
                                              VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2, VK_SHADER_STAGE_ALL, nullptr,
                                              VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT | VK_DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT
                                                  | VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT);
  NVVK_CHECK(m_resources.descriptorBinding[0].createDescriptorSetLayout(
      m_device, VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT, &m_resources.descriptorSetLayout[0]));
  NVVK_DBG_NAME(m_resources.descriptorSetLayout[0]);

  std::vector<VkDescriptorPoolSize> poolSize  = m_resources.descriptorBinding[0].calculatePoolSizes();
  VkDescriptorPoolCreateInfo        dpoolInfo = {
             .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
             .flags = VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT |  // allows descriptor sets to be updated after they have been bound to a command buffer
               VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,  // individual descriptor sets can be freed from the descriptor pool
             .maxSets       = 10,                                         // For all DLSS images
             .poolSizeCount = uint32_t(poolSize.size()),
             .pPoolSizes    = poolSize.data(),
  };
  NVVK_CHECK(vkCreateDescriptorPool(m_device, &dpoolInfo, nullptr, &m_resources.descriptorPool));
  NVVK_DBG_NAME(m_resources.descriptorPool);

  VkDescriptorSetAllocateInfo allocInfo = {
      .sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
      .descriptorPool     = m_resources.descriptorPool,
      .descriptorSetCount = 1,
      .pSetLayouts        = &m_resources.descriptorSetLayout[0],
  };
  NVVK_CHECK(vkAllocateDescriptorSets(m_device, &allocInfo, &m_resources.descriptorSet));
  NVVK_DBG_NAME(m_resources.descriptorSet);


  // 1: Descriptor PUSH: top level acceleration structure, output images, and QOLDS buffers
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eTlas,
                                              VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR, 1, VK_SHADER_STAGE_ALL);
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eOutImages, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 10,
                                              VK_SHADER_STAGE_ALL);
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eQoldsMatrices, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                                              1, VK_SHADER_STAGE_ALL);
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eQoldsSeeds, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1,
                                              VK_SHADER_STAGE_ALL);

  // RMIP displacement bindings (8-11)
  // Note: Keep total push descriptors <= 32 (maxPushDescriptors limit)
  // Current: 1 (TLAS) + 10 (output images) + 8 (RMIP) + 8 (displacement) + 1 + 1 = 29
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eRmipTextures,
                                              VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 8, VK_SHADER_STAGE_ALL);  // Array of RMIP textures
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eDisplacementTextures,
                                              VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 8, VK_SHADER_STAGE_ALL);  // Displacement textures
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eRmipSampler,
                                              VK_DESCRIPTOR_TYPE_SAMPLER, 1, VK_SHADER_STAGE_ALL);  // RMIP sampler
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eDisplacementSampler,
                                              VK_DESCRIPTOR_TYPE_SAMPLER, 1, VK_SHADER_STAGE_ALL);  // Displacement sampler
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eDisplacementFactors,
                                              VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_ALL);  // Displacement factors from glTF
  m_resources.descriptorBinding[1].addBinding(shaderio::BindingPoints::eMaterialDispIndex,
                                              VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_ALL);  // Material ID -> displacement array index

  NVVK_CHECK(m_resources.descriptorBinding[1].createDescriptorSetLayout(m_device, VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR,
                                                                        &m_resources.descriptorSetLayout[1]));
  NVVK_DBG_NAME(m_resources.descriptorSetLayout[1]);
}

//--------------------------------------------------------------------------------------------------
// Recompile the shaders of the current renderer. See onUIMenu() for the key binding
void GltfRenderer::compileShaders()
{
  nvutils::ScopedTimer st(__FUNCTION__);
  if(m_resources.settings.renderSystem == RenderingMode::ePathtracer)
  {
    m_pathTracer.compileShader(m_resources);
  }
  else
  {
    m_rasterizer.compileShader(m_resources);
  }
}

//--------------------------------------------------------------------------------------------------
// Update the textures: this is called when the scene is loaded
// Textures are updated in the descriptor set (0)
void GltfRenderer::updateTextures()
{
  // Now do the textures
  nvvk::WriteSetContainer write{};
  VkWriteDescriptorSet allTextures = m_resources.descriptorBinding[0].getWriteSet(shaderio::BindingPoints::eTextures);
  allTextures.dstSet               = m_resources.descriptorSet;
  allTextures.descriptorCount      = m_resources.sceneVk.nbTextures();
  if(allTextures.descriptorCount == 0)
    return;
  write.append(allTextures, m_resources.sceneVk.textures().data());
  vkUpdateDescriptorSets(m_device, write.size(), write.data(), 0, nullptr);
}

//--------------------------------------------------------------------------------------------------
// Update the HDR images : add the 2D images to allTextures and the cube images to allTexturesCube
//
void GltfRenderer::updateHdrImages()
{
  const std::vector<nvvk::Image>& hdrPreconvolutedTextures = m_resources.hdrDome.getTextures();
  nvvk::WriteSetContainer         write{};
  VkWriteDescriptorSet hdrTextures = m_resources.descriptorBinding[0].getWriteSet(shaderio::BindingPoints::eTexturesHdr,
                                                                                  m_resources.descriptorSet, HDR_IMAGE_INDEX, 1U);
  // Adding the HDR image (RGBA32F)
  write.append(hdrTextures, m_resources.hdrIbl.getHdrImage());
  // Add pre-integrated LUT BRDF
  hdrTextures.dstArrayElement = HDR_LUT_INDEX;
  write.append(hdrTextures, hdrPreconvolutedTextures[2]);

  // Adding cube images: diffuse, glossy
  VkWriteDescriptorSet hdrTexturesCube =
      m_resources.descriptorBinding[0].getWriteSet(shaderio::BindingPoints::eTexturesCube, m_resources.descriptorSet, 0, 2U);
  write.append(hdrTexturesCube, m_resources.hdrDome.getTextures().data());

  vkUpdateDescriptorSets(m_device, write.size(), write.data(), 0, nullptr);
}

//--------------------------------------------------------------------------------------------------
// Reset the frame counter
void GltfRenderer::resetFrame()
{
  m_resources.frameCount = -1;
}

//--------------------------------------------------------------------------------------------------
// Update the frame counter
// This is called every frame to update the frame counter or to reset it if the camera has changed
// The frame counter is used to limit the number of frames rendered
// If the frame counter is greater than the maximum number of frames, the rendering stops
// Returns true if the frame counter is less than the maximum number of frames
bool GltfRenderer::updateFrameCounter()
{
  static float     ref_fov{0};
  static glm::mat4 ref_cam_matrix;

  const auto& m   = m_cameraManip->getViewMatrix();
  const auto  fov = m_cameraManip->getFov();

  if(ref_cam_matrix != m || ref_fov != fov)
  {
    resetFrame();
    ref_cam_matrix = m;
    ref_fov        = fov;
  }

  if(m_resources.frameCount >= m_resources.settings.maxFrames)
  {
    return false;
  }
  m_resources.frameCount++;
  return true;
}

//--------------------------------------------------------------------------------------------------
// Create or load the HDR environment map
// If the filename is empty, a default environment map (empty) is created, which allow the descriptor set to be updated
void GltfRenderer::createHDR(const std::filesystem::path& hdrFilename)
{
  VkCommandBuffer cmd{};
  nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);
  nvvk::StagingUploader uploader;
  uploader.init(&m_resources.allocator, true);

  // Load an HDR and create the important sampling acceleration structure
  std::filesystem::path filename;
  if(!hdrFilename.empty())
    filename = nvutils::findFile(hdrFilename, nvsamples::getResourcesDirs(), false);
  m_resources.hdrIbl.destroyEnvironment();
  m_resources.hdrIbl.loadEnvironment(cmd, uploader, filename, true);

  uploader.cmdUploadAppended(cmd);

  // Generate mipmaps for the HDR image
  VkExtent2D hdrSize = m_resources.hdrIbl.getHdrImageSize();
  if(hdrSize.width > 1 && hdrSize.height > 1)
  {
    nvvk::cmdGenerateMipmaps(cmd, m_resources.hdrIbl.getHdrImage().image, hdrSize, nvvk::mipLevels(hdrSize));
  }

  nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);
  uploader.deinit();

  // Create the diffuse and glossy cube maps for the HDR image (raster)
  m_resources.hdrDome.create(m_resources.hdrIbl.getDescriptorSet(), m_resources.hdrIbl.getDescriptorSetLayout(),
                             std::span(hdr_prefilter_diffuse_slang), std::span(hdr_prefilter_glossy_slang),
                             std::span(hdr_integrate_brdf_slang), std::span(hdr_dome_slang));

  updateHdrImages();
  m_resources.hdrDome.setOutImage(m_resources.gBuffers.getDescriptorImageInfo(Resources::eImgRendered));
  // addToRecentFiles(hdrFilename);
}

//--------------------------------------------------------------------------------------------------
// Destroy the resources
// Resource cleanup follows a specific order to prevent validation errors:
// 1. First flush any pending command buffers to ensure GPU work is complete
// 2. Then destroy higher-level objects before their dependencies
// 3. Finally clean up allocator after all resources using it are destroyed
// This ensures proper synchronization and prevents use-after-free errors
void GltfRenderer::destroyResources()
{
  // Process any remaining command buffers in the queue
  {
    std::lock_guard<std::mutex> lock(m_cmdBufferQueueMutex);
    while(!m_cmdBufferQueue.empty())
    {
      CommandBufferInfo cmdInfo = m_cmdBufferQueue.front();
      m_cmdBufferQueue.pop();
      nvvk::endSingleTimeCommands(cmdInfo.cmdBuffer, m_device, m_transientCmdPool, m_app->getQueue(0).queue);
    }
  }

  m_resources.allocator.destroyBuffer(m_resources.bFrameInfo);
  m_resources.allocator.destroyBuffer(m_resources.bSkyParams);
  m_resources.allocator.destroyBuffer(m_resources.bQoldsMatrices);
  m_resources.allocator.destroyBuffer(m_resources.bQoldsSeeds);
  m_resources.allocator.destroyBuffer(m_resources.bDisplacementFactors);
  m_resources.allocator.destroyBuffer(m_resources.bMaterialDispIndex);

  vkDestroyDescriptorSetLayout(m_device, m_resources.descriptorSetLayout[0], nullptr);
  vkDestroyDescriptorSetLayout(m_device, m_resources.descriptorSetLayout[1], nullptr);
  vkDestroyDescriptorPool(m_device, m_resources.descriptorPool, nullptr);
  vkDestroyCommandPool(m_device, m_transientCmdPool, nullptr);

  m_profilerGpuTimer.deinit();
  g_profilerManager.destroyTimeline(m_profilerTimeline);
  m_silhouette.deinit(m_resources);

  m_resources.tonemapper.deinit();
  m_resources.gBuffers.deinit();
  m_resources.sceneVk.deinit();
  m_resources.sceneRtx.deinit();
  m_resources.hdrIbl.deinit();
  m_resources.hdrDome.deinit();
  m_resources.samplerPool.deinit();
  m_resources.staging.deinit();
  m_rayPicker.deinit();

  // Destroy convergence analyzer before allocator to prevent memory leak
  m_convergenceAnalyzer.destroy();

  // Destroy VNDF analyzer before allocator to prevent memory leak
  m_vndfAnalyzer.destroy();

  // Destroy MSX analyzer before allocator to prevent memory leak
  m_msxAnalyzer.destroy();

  // Clean up RMIP resources BEFORE destroying allocator
  for (auto& rmipData : m_displacementRMIPs)
  {
      if (rmipData.view != VK_NULL_HANDLE)
          vkDestroyImageView(m_device, rmipData.view, nullptr);
      if (rmipData.image.image != VK_NULL_HANDLE)
          m_resources.allocator.destroyImage(rmipData.image);
  }
  m_displacementRMIPs.clear();

  // Deinit RMIP builder and AABB computer BEFORE destroying allocator (they have internal buffers)
  m_rmipBuilder.deinit();
  m_aabbComputer.deinit();

  // NOW it's safe to destroy the allocator
  m_resources.allocator.deinit();
}


//--------------------------------------------------------------------------------------------------
// Update the animation
bool GltfRenderer::updateAnimation(VkCommandBuffer cmd)
{
  if(m_resources.scene.hasAnimation() && m_animControl.doAnimation())
  {
    NVVK_DBG_SCOPE(cmd);  // <-- Helps to debug in NSight
    float                    deltaTime = m_animControl.deltaTime();
    nvvkgltf::AnimationInfo& animInfo  = m_resources.scene.getAnimationInfo(m_animControl.currentAnimation);
    if(m_animControl.isReset())
    {
      animInfo.reset();
    }
    else
    {
      animInfo.incrementTime(deltaTime);
    }

    m_resources.scene.updateAnimation(m_animControl.currentAnimation);
    m_resources.scene.updateRenderNodes();

    m_animControl.clearStates();

    return true;
  }
  return false;
}

//--------------------------------------------------------------------------------------------------
// Update the scene based on changes from UI or animation
// This is a critical synchronization point for changes to scene data, ensuring that:
// 1. UI modifications to materials, lights, and transformations are propagated to GPU buffers
// 2. Animation changes are reflected in acceleration structures
// 3. Vulkan buffers and acceleration structures remain in sync with scene state
// 4. Frame counter is reset when needed to restart progressive rendering
// Returns true if any changes were made that require re-rendering
bool GltfRenderer::updateSceneChanges(VkCommandBuffer cmd, bool didAnimate)
{
  bool changed = m_uiSceneGraph.hasAnyChanges();
  if(m_uiSceneGraph.hasMaterialChanged())
  {
    m_resources.sceneVk.updateMaterialBuffer(cmd, m_resources.staging, m_resources.scene);
    updateDisplacementFactors(cmd);  // Also update displacement factors if they changed
  }
  if(m_uiSceneGraph.hasLightChanged())
  {
    m_resources.sceneVk.updateRenderLightsBuffer(cmd, m_resources.staging, m_resources.scene);
  }
  if(m_resources.dirtyFlags.test(DirtyFlags::eVulkanScene))
  {
    m_resources.scene.updateRenderNodes();
    m_resources.sceneVk.updateRenderNodesBuffer(cmd, m_resources.staging, m_resources.scene);
    m_resources.sceneVk.updateRenderPrimitivesBuffer(cmd, m_resources.staging, m_resources.scene);
    m_resources.sceneVk.updateRenderLightsBuffer(cmd, m_resources.staging, m_resources.scene);
    m_resources.dirtyFlags.reset(DirtyFlags::eVulkanScene);
    changed = true;
  }
  if(m_uiSceneGraph.hasTransformChanged() || didAnimate)
  {
    m_resources.scene.updateRenderNodes();
    m_resources.sceneVk.updateRenderNodesBuffer(cmd, m_resources.staging, m_resources.scene);
    m_resources.sceneVk.updateRenderPrimitivesBuffer(cmd, m_resources.staging, m_resources.scene);
    m_resources.sceneVk.updateRenderLightsBuffer(cmd, m_resources.staging, m_resources.scene);
    // Make sure the staging buffers are uploaded before the acceleration structures are updated
    m_resources.staging.cmdUploadAppended(cmd);
    // Ensure all buffer copy operations complete before acceleration structure build begins
    nvvk::cmdMemoryBarrier(cmd, VK_PIPELINE_STAGE_2_COPY_BIT, VK_PIPELINE_STAGE_2_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,
                           VK_ACCESS_2_TRANSFER_WRITE_BIT, VK_ACCESS_2_SHADER_READ_BIT);
    m_resources.sceneRtx.updateBottomLevelAS(cmd, m_resources.scene);
    m_resources.sceneRtx.updateTopLevelAS(cmd, m_resources.staging, m_resources.scene);
  }
  if(m_uiSceneGraph.hasMaterialFlagChanges() || m_uiSceneGraph.hasVisibilityChanged())
  {
    m_resources.scene.updateRenderNodes();
    m_resources.sceneRtx.updateTopLevelAS(cmd, m_resources.staging, m_resources.scene);
  }
  if(changed || didAnimate)
  {
    m_resources.staging.cmdUploadAppended(cmd);
    resetFrame();
  }
  m_uiSceneGraph.resetChanges();

  return changed || didAnimate;
}


//--------------------------------------------------------------------------------------------------
// Create a mapping from node ID to render node index for faster lookups
// This is a critical optimization that enables O(1) lookups from scene graph nodes to renderer nodes,
// enabling quick interaction between UI selections and the actual render objects.
// Called during scene creation and whenever the scene structure changes.
void GltfRenderer::updateNodeToRenderNodeMap()
{
  m_nodeToRenderNodeMap.clear();
  auto& renderNodes = m_resources.scene.getRenderNodes();
  for(size_t i = 0; i < renderNodes.size(); i++)
  {
    m_nodeToRenderNodeMap[renderNodes[i].refNodeID] = static_cast<int>(i);
  }
}


//--------------------------------------------------------------------------------------------------
// Process queued command buffers in FIFO order
// Those command buffers are created in worker threads while loading or processing a scene
// It will process one command buffer at a time, then give back control to the UI
// Command buffers can be of two types:
// 1. Regular command buffers (isBlasBuild=false): These execute scene creation, texture uploads, etc.
// 2. BLAS build command buffers (isBlasBuild=true): These build bottom-level acceleration structures
//    and are immediately followed by BLAS compaction to optimize memory usage
//
bool GltfRenderer::processQueuedCommandBuffers()
{
  std::lock_guard<std::mutex> lock(m_cmdBufferQueueMutex);
  if(!m_cmdBufferQueue.empty())
  {
    SCOPED_TIMER("Processing queued command buffer\n");

    // Get the command buffer information from the queue
    CommandBufferInfo cmdInfo = m_cmdBufferQueue.front();
    m_cmdBufferQueue.pop();

    // Execute the command buffer
    nvvk::endSingleTimeCommands(cmdInfo.cmdBuffer, m_device, m_transientCmdPool, m_app->getQueue(0).queue);

    // If this was a BLAS build command, immediately compact after it
    if(cmdInfo.isBlasBuild)
    {
      // Create a command buffer for compaction
      VkCommandBuffer cmd{};
      nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);
      m_resources.sceneRtx.cmdCompactBlas(cmd);
      // Submit the compaction command buffer immediately
      nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);
    }
    if(m_cmdBufferQueue.empty())
      m_resources.staging.releaseStaging(true);
    return true;  // Command buffer was processed
  }
  return false;  // No command buffer was processed
}

//--------------------------------------------------------------------------------------------------
// Convergence Testing
//--------------------------------------------------------------------------------------------------

void GltfRenderer::startConvergenceTest(bool useQOLDS)
{
  // Capture reference image first (must be at high sample count)
  if(m_resources.frameCount < 100)
  {
    printf("Warning: Current frame count is %d. Please render to 512+ samples before starting test.\n", m_resources.frameCount);
    printf("Capturing reference anyway, but results may be inaccurate.\n");
  }

  // Capture reference from current frame
  VkCommandBuffer cmd{};
  nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);

  VkImage  refImage = m_resources.gBuffers.getColorImage(Resources::eImgRendered);
  VkExtent2D size   = m_resources.gBuffers.getSize();

  m_convergenceAnalyzer.captureReference(cmd, refImage, size);

  nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);

  // Finalize reference capture after GPU sync
  m_convergenceAnalyzer.finalizeReferenceCapture();

  // Start convergence session
  std::string sessionName = useQOLDS ? "qolds_test" : "pcg_test";
  m_convergenceAnalyzer.startSession(sessionName, useQOLDS);

  // Set test state
  m_convergenceTestActive          = true;
  m_convergenceTestUseQOLDS        = useQOLDS;
  m_convergenceTestCurrentIndex    = 0;
  m_convergenceTestStartTime       = std::chrono::steady_clock::now();
  m_convergenceTestLastCaptureTime = m_convergenceTestStartTime;  // Initialize for delta calculation

  // Set QOLDS mode in path tracer (both push constant and checkbox state)
  if(m_pathTracer.m_pushConst.useQOLDS != (useQOLDS ? 1 : 0))
  {
    m_pathTracer.m_pushConst.useQOLDS = useQOLDS ? 1 : 0;
  }
  m_pathTracer.m_useQOLDS = useQOLDS;  // Update checkbox state to reflect current sampling method

  // Disable auto SPP and set SPP to 1 for accurate convergence testing
  m_pathTracer.m_adaptiveSampling    = false;  
  m_pathTracer.m_pushConst.numSamples = 1;    

  // Reset rendering to start fresh
  resetFrame();

  printf("Convergence test started: %s (will capture at %zu sample counts)\n",
         sessionName.c_str(), m_convergenceTestSampleCounts.size());
}

void GltfRenderer::startCombinedConvergenceTest()
{
  // Set flag to run both tests sequentially
  m_convergenceTestRunBoth = true;

  printf("Starting combined convergence test (QOLDS + PCG)...\n");

  // Start with QOLDS test first
  startConvergenceTest(true);
}

void GltfRenderer::updateConvergenceTest(VkCommandBuffer cmd)
{
  if(!m_convergenceTestActive)
    return;

  // Finalize previous capture if pending (by now the GPU has completed the copy)
  if(m_convergenceTestPendingFinalize)
  {
    m_convergenceAnalyzer.finalizeFrameCapture();
    m_convergenceTestPendingFinalize = false;
  }

  // Check if we've reached the next sample count milestone
  if(m_convergenceTestCurrentIndex >= m_convergenceTestSampleCounts.size())
  {
    // Current test complete
    m_convergenceTestActive = false;
    m_convergenceAnalyzer.endSession();

    // Export results with timestamp to test folder
    std::string sessionName = m_convergenceTestUseQOLDS ? "qolds_test" : "pcg_test";

    // Generate timestamp string (YYYYMMDD_HHMMSS)
    auto        now       = std::chrono::system_clock::now();
    std::time_t nowTime   = std::chrono::system_clock::to_time_t(now);
    std::tm     localTime = {};
#ifdef _WIN32
    localtime_s(&localTime, &nowTime);
#else
    localtime_r(&nowTime, &localTime);
#endif
    char timestamp[32];
    std::strftime(timestamp, sizeof(timestamp), "%Y%m%d_%H%M%S", &localTime);

    // Create test directory if it doesn't exist
    std::filesystem::path testDir = "../test";
    if(!std::filesystem::exists(testDir))
    {
      std::filesystem::create_directories(testDir);
    }

    std::string csvFile = (testDir / (sessionName + "_" + timestamp + ".csv")).string();
    m_convergenceAnalyzer.exportToCSV(csvFile);

    auto duration = std::chrono::steady_clock::now() - m_convergenceTestStartTime;
    auto seconds  = std::chrono::duration_cast<std::chrono::seconds>(duration).count();

    printf("Convergence test completed in %lld seconds. Results saved to %s\n", (long long)seconds, csvFile.c_str());

    // If running combined test and QOLDS just finished, start PCG test
    if(m_convergenceTestRunBoth && m_convergenceTestUseQOLDS)
    {
      printf("Starting PCG test (part 2 of combined test)...\n");
      startConvergenceTest(false);  // Start PCG test
    }
    else
    {
      // All tests done
      m_convergenceTestRunBoth = false;
    }
    return;
  }

  uint32_t targetSamples = m_convergenceTestSampleCounts[m_convergenceTestCurrentIndex];

  // Wait until we've accumulated enough samples
  if(static_cast<uint32_t>(m_resources.frameCount + 1) >= targetSamples)
  {
    // Capture this milestone (records GPU copy command)
    VkImage    testImage = m_resources.gBuffers.getColorImage(Resources::eImgRendered);
    VkExtent2D size      = m_resources.gBuffers.getSize();

    auto   currentTime  = std::chrono::steady_clock::now();
    auto   duration     = currentTime - m_convergenceTestStartTime;
    auto   deltaDuration = currentTime - m_convergenceTestLastCaptureTime;
    double timeMs       = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
    double timeDeltaMs  = std::chrono::duration_cast<std::chrono::milliseconds>(deltaDuration).count();

    m_convergenceAnalyzer.captureFrame(cmd, testImage, targetSamples, timeMs, timeDeltaMs);

    // Update last capture time for next delta calculation
    m_convergenceTestLastCaptureTime = currentTime;

    // Mark as pending - will finalize on next frame after GPU completes
    m_convergenceTestPendingFinalize = true;

    // Move to next milestone
    m_convergenceTestCurrentIndex++;

    printf("Recorded capture %zu/%zu at %u samples (delta: %.0fms)\n", m_convergenceTestCurrentIndex,
           m_convergenceTestSampleCounts.size(), targetSamples, timeDeltaMs);
  }
}

//--------------------------------------------------------------------------------------------------
// VNDF Analysis - Compare Bounded VNDF vs Standard VNDF sampling
//--------------------------------------------------------------------------------------------------

void GltfRenderer::startVNDFTest(bool useBoundedVNDF)
{
  // Capture reference image first (must be at high sample count)
  if(m_resources.frameCount < 100)
  {
    printf("Warning: Current frame count is %d. Please render to 512+ samples before starting test.\n", m_resources.frameCount);
    printf("Capturing reference anyway, but results may be inaccurate.\n");
  }

  // Capture reference from current frame
  VkCommandBuffer cmd{};
  nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);

  VkImage    refImage = m_resources.gBuffers.getColorImage(Resources::eImgRendered);
  VkExtent2D size     = m_resources.gBuffers.getSize();

  m_vndfAnalyzer.captureReference(cmd, refImage, size);

  nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);

  // Finalize reference capture after GPU sync
  m_vndfAnalyzer.finalizeReferenceCapture();

  // Start VNDF session
  std::string sessionName = useBoundedVNDF ? "bounded_vndf_test" : "standard_vndf_test";

  // Get current roughness from scene materials
  float currentRoughness = 0.5f;  // Default fallback
  const auto& model = m_resources.scene.getModel();
  if(!model.materials.empty())
  {
    // Use roughness from first material (typically the main material being tested)
    currentRoughness = static_cast<float>(model.materials[0].pbrMetallicRoughness.roughnessFactor);
  }

  m_vndfAnalyzer.startSession(sessionName, useBoundedVNDF, currentRoughness);

  // Set test state
  m_vndfTestActive          = true;
  m_vndfTestUseBoundedVNDF  = useBoundedVNDF;
  m_vndfTestCurrentIndex    = 0;
  m_vndfTestStartTime       = std::chrono::steady_clock::now();
  m_vndfTestLastCaptureTime = m_vndfTestStartTime;

  // Set Bounded VNDF mode in path tracer
  m_pathTracer.m_useBoundedVNDF         = useBoundedVNDF;
  m_pathTracer.m_pushConst.useBoundedVNDF = useBoundedVNDF ? 1 : 0;

  // Disable auto SPP and set SPP to 1 for accurate testing
  m_pathTracer.m_adaptiveSampling     = false;
  m_pathTracer.m_pushConst.numSamples = 1;

  // Reset rendering to start fresh
  resetFrame();

  printf("VNDF test started: %s (will capture at %zu sample counts)\n",
         sessionName.c_str(), m_vndfTestSampleCounts.size());
}

void GltfRenderer::updateVNDFTest(VkCommandBuffer cmd)
{
  if(!m_vndfTestActive)
    return;

  // Finalize previous capture if pending
  if(m_vndfTestPendingFinalize)
  {
    m_vndfAnalyzer.finalizeFrameCapture();
    m_vndfTestPendingFinalize = false;
  }

  // Check if test is complete
  if(m_vndfTestCurrentIndex >= m_vndfTestSampleCounts.size())
  {
    // Current test complete
    m_vndfTestActive = false;
    m_vndfAnalyzer.endSession();

    // Export results with timestamp to test folder
    std::string sessionName = m_vndfTestUseBoundedVNDF ? "bounded_vndf" : "standard_vndf";

    // Generate timestamp string
    auto        now       = std::chrono::system_clock::now();
    std::time_t nowTime   = std::chrono::system_clock::to_time_t(now);
    std::tm     localTime = {};
#ifdef _WIN32
    localtime_s(&localTime, &nowTime);
#else
    localtime_r(&nowTime, &localTime);
#endif
    char timestamp[32];
    std::strftime(timestamp, sizeof(timestamp), "%Y%m%d_%H%M%S", &localTime);

    // Create test directory if it doesn't exist
    std::filesystem::path testDir = "../test/vndf_analysis";
    if(!std::filesystem::exists(testDir))
    {
      std::filesystem::create_directories(testDir);
    }

    std::string csvFile = (testDir / (sessionName + "_" + timestamp + ".csv")).string();
    m_vndfAnalyzer.exportToCSV(csvFile);

    auto duration = std::chrono::steady_clock::now() - m_vndfTestStartTime;
    auto seconds  = std::chrono::duration_cast<std::chrono::seconds>(duration).count();

    printf("VNDF test completed in %lld seconds. Results saved to %s\n", (long long)seconds, csvFile.c_str());

    // If running combined test and Bounded just finished, start Standard test
    if(m_vndfTestRunBoth && m_vndfTestUseBoundedVNDF)
    {
      printf("Starting Standard VNDF test (part 2 of combined test)...\n");
      startVNDFTest(false);  // Start Standard VNDF test
    }
    else
    {
      // All tests done
      m_vndfTestRunBoth = false;
    }
    return;
  }

  uint32_t targetSamples = m_vndfTestSampleCounts[m_vndfTestCurrentIndex];

  // Wait until we've accumulated enough samples
  if(static_cast<uint32_t>(m_resources.frameCount + 1) >= targetSamples)
  {
    // Capture this milestone
    VkImage    testImage = m_resources.gBuffers.getColorImage(Resources::eImgRendered);
    VkExtent2D size      = m_resources.gBuffers.getSize();

    auto   currentTime   = std::chrono::steady_clock::now();
    auto   duration      = currentTime - m_vndfTestStartTime;
    double timeMs        = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();

    // For VNDF analysis, we track rejection statistics
    // These would ideally come from shader counters, but for now use estimates
    uint64_t totalSamples    = static_cast<uint64_t>(targetSamples) * size.width * size.height;
    uint64_t rejectedSamples = 0;  // TODO: Implement shader counter for actual rejection tracking

    m_vndfAnalyzer.captureFrame(cmd, testImage, targetSamples, totalSamples, rejectedSamples, timeMs);

    // Update last capture time
    m_vndfTestLastCaptureTime = currentTime;

    // Mark as pending
    m_vndfTestPendingFinalize = true;

    // Move to next milestone
    m_vndfTestCurrentIndex++;

    printf("VNDF: Recorded capture %zu/%zu at %u samples\n", m_vndfTestCurrentIndex,
           m_vndfTestSampleCounts.size(), targetSamples);
  }
}

//--------------------------------------------------------------------------------------------------
// MSX Analysis - Test Fast-MSX Multiple Scattering Implementation
//--------------------------------------------------------------------------------------------------

void GltfRenderer::setupMSXAnalyzerCallbacks()
{
  // Callbacks are no longer needed with the async pattern
  // The analyzer now uses captureReference/captureFrame directly
  printf("MSX Analyzer: Using async capture pattern\n");
}

void GltfRenderer::startMSXTest(bool useFastMSX)
{
  // Capture reference image first (must be at high sample count)
  if(m_resources.frameCount < 100)
  {
    printf("Warning: Current frame count is %d. Please render to 512+ samples before starting test.\n", m_resources.frameCount);
    printf("Capturing reference anyway, but results may be inaccurate.\n");
  }

  // Capture reference from current high-SPP frame
  VkCommandBuffer cmd{};
  nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);

  VkImage    refImage = m_resources.gBuffers.getColorImage(Resources::eImgRendered);
  VkExtent2D size     = m_resources.gBuffers.getSize();

  m_msxAnalyzer.captureReference(cmd, refImage, size);

  nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);

  // Finalize reference capture after GPU sync
  m_msxAnalyzer.finalizeReferenceCapture();

  // Set the path tracer to use the requested method
  m_pathTracer.m_useFastMSX = useFastMSX;
  m_msxTestUseFastMSX = useFastMSX;

  // Start MSX session
  std::string sessionName = useFastMSX ? "fastmsx_test" : "ggx_test";
  m_msxAnalyzer.startSession(sessionName, useFastMSX, matforge::TestMaterial::Achromatic, 0.5f);

  // Set test state
  m_msxTestActive          = true;
  m_msxTestPendingFinalize = false;
  m_msxTestCurrentIndex    = 0;
  m_msxTestStartTime       = std::chrono::steady_clock::now();

  // Configure path tracer for testing
  m_pathTracer.m_adaptiveSampling     = false;
  m_pathTracer.m_pushConst.numSamples = 1;

  // Reset rendering to start fresh
  resetFrame();

  printf("MSX test started: %s (will capture at %zu sample counts)\n",
         sessionName.c_str(), m_msxTestSampleCounts.size());
}

void GltfRenderer::updateMSXTest(VkCommandBuffer cmd)
{
  if(!m_msxTestActive)
    return;

  // Finalize previous capture if pending
  if(m_msxTestPendingFinalize)
  {
    m_msxAnalyzer.finalizeFrameCapture();
    m_msxTestPendingFinalize = false;
  }

  // Check if current session test is complete
  if(m_msxTestCurrentIndex >= m_msxTestSampleCounts.size())
  {
    // Current session complete
    m_msxTestActive = false;
    m_msxAnalyzer.endSession();

    // Generate timestamp for export
    auto        now       = std::chrono::system_clock::now();
    std::time_t nowTime   = std::chrono::system_clock::to_time_t(now);
    std::tm     localTime = {};
#ifdef _WIN32
    localtime_s(&localTime, &nowTime);
#else
    localtime_r(&nowTime, &localTime);
#endif
    char timestamp[32];
    std::strftime(timestamp, sizeof(timestamp), "%Y%m%d_%H%M%S", &localTime);

    std::filesystem::path testDir = "../test/msx_analysis";
    if(!std::filesystem::exists(testDir))
    {
      std::filesystem::create_directories(testDir);
    }

    // Export CSV with method name in filename - only export current method's data
    std::string methodName = m_msxTestUseFastMSX ? "fastmsx" : "ggx";
    std::string csvFile = (testDir / (methodName + "_" + std::string(timestamp) + ".csv")).string();
    m_msxAnalyzer.exportMetricsCSV(csvFile, m_msxTestUseFastMSX);

    auto duration = std::chrono::steady_clock::now() - m_msxTestStartTime;
    auto seconds  = std::chrono::duration_cast<std::chrono::seconds>(duration).count();

    printf("MSX test (%s) completed in %lld seconds. Results saved to %s\n",
           m_msxTestUseFastMSX ? "FastMSX" : "GGX", (long long)seconds, csvFile.c_str());

    // If running combined test and FastMSX just finished, start GGX test
    if(m_msxTestRunBoth && m_msxTestUseFastMSX)
    {
      printf("Starting GGX test (part 2 of combined test)...\n");
      startMSXTest(false);  // Start GGX test
    }
    else
    {
      // All tests done
      m_msxTestRunBoth = false;
    }
    return;
  }

  uint32_t targetSamples = m_msxTestSampleCounts[m_msxTestCurrentIndex];

  // Wait until we've accumulated enough samples
  if(static_cast<uint32_t>(m_resources.frameCount + 1) >= targetSamples)
  {
    // Capture this milestone
    VkImage testImage = m_resources.gBuffers.getColorImage(Resources::eImgRendered);

    auto   currentTime = std::chrono::steady_clock::now();
    auto   duration    = currentTime - m_msxTestStartTime;
    double timeMs      = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();

    m_msxAnalyzer.captureFrame(cmd, testImage, targetSamples, timeMs);

    // Mark as pending
    m_msxTestPendingFinalize = true;

    // Move to next milestone
    m_msxTestCurrentIndex++;

    printf("MSX (%s): Recorded capture %zu/%zu at %u samples\n",
           m_msxTestUseFastMSX ? "FastMSX" : "GGX",
           m_msxTestCurrentIndex, m_msxTestSampleCounts.size(), targetSamples);
  }
}

void GltfRenderer::buildDisplacementRMIPs(VkCommandBuffer cmd)
{
    NVVK_DBG_SCOPE(cmd);
    SCOPED_TIMER(__FUNCTION__);

    cleanupDisplacementRMIPs();

    // Reset descriptor pool to free all previously allocated descriptor sets
    m_rmipBuilder.resetDescriptorPool();

    const tinygltf::Model& model = m_resources.scene.getModel();

    // Resize vector to hold displacement data for all materials
    m_displacementRMIPs.resize(model.materials.size());

    for (size_t matIdx = 0; matIdx < model.materials.size(); matIdx++)
    {
        const tinygltf::Material& material = model.materials[matIdx];

        KHR_materials_displacement displacement = tinygltf::utils::getDisplacement(material);

        if (displacement.displacementGeometryTexture.index < 0)
            continue;  // No displacement texture

        int textureIdx = displacement.displacementGeometryTexture.index;
        if (textureIdx < 0 || textureIdx >= static_cast<int>(model.textures.size()))
            continue;

        // Get displacement factor
        float displacementFactor = displacement.displacementGeometryFactor;
 
        const tinygltf::Texture& texture = model.textures[textureIdx];
        int imageIdx = texture.source;

        if (imageIdx < 0 || imageIdx >= static_cast<int>(model.images.size()))
            continue;

        // Get the Vulkan texture
        const auto& sceneTextures = m_resources.sceneVk.textures();
        if (textureIdx >= static_cast<int>(sceneTextures.size()))
            continue;

        VkImage     displacementImage = sceneTextures[textureIdx].image;
        VkImageView displacementView = sceneTextures[textureIdx].descriptor.imageView;

        // Get image resolution
        // Note: tinygltf doesn't populate width/height for external URI images,
        // so we need to read them from the actual image file
        const tinygltf::Image& image = model.images[imageIdx];
        int width = image.width;
        int height = image.height;

        // If dimensions are not set (external URI), load them from the file
        if (width <= 0 || height <= 0)
        {
            // Construct full path to image file
            std::filesystem::path basePath = m_resources.scene.getFilename().parent_path();
            std::filesystem::path imagePath = basePath / image.uri;

            int channels;
            if (!stbi_info(imagePath.string().c_str(), &width, &height, &channels))
            {
                LOGW("Failed to read image info for displacement map: %s\n", imagePath.string().c_str());
                continue;
            }
            LOGI("Loaded image dimensions from file: %s (%dx%d)\n", image.uri.c_str(), width, height);
        }

        // RMIP requires square, power-of-2 textures
        if (width != height)
        {
            LOGW("Displacement map %d is not square (%dx%d), skipping RMIP\n",
                imageIdx, width, height);
            continue;
        }

        uint32_t resolution = width;

        // Validate power of 2
        if ((resolution & (resolution - 1)) != 0)
        {
            LOGW("Displacement map %d is not power of 2 (%dx%d), skipping RMIP\n",
                imageIdx, width, height);
            continue;
        }

        // Calculate RMIP layers
        uint32_t maxLevel = static_cast<uint32_t>(std::log2(resolution));
        uint32_t numLayers = (maxLevel + 1) * (maxLevel + 1);

        // Create RMIP output image
        RmipData rmipData;

        VkImageCreateInfo rmipImageInfo{
            .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = VK_IMAGE_TYPE_2D,
            .format = VK_FORMAT_R32G32_SFLOAT,  // (min, max) pairs
            .extent = {resolution, resolution, 1},
            .mipLevels = 1,
            .arrayLayers = numLayers,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        };

        NVVK_CHECK(m_resources.allocator.createImage(rmipData.image, rmipImageInfo));
        NVVK_DBG_NAME(rmipData.image.image);

        VkImageViewCreateInfo viewInfo{
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = rmipData.image.image,
            .viewType = VK_IMAGE_VIEW_TYPE_2D_ARRAY,
            .format = VK_FORMAT_R32G32_SFLOAT,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = numLayers
            },
        };

        NVVK_CHECK(vkCreateImageView(m_device, &viewInfo, nullptr, &rmipData.view));
        NVVK_DBG_NAME(rmipData.view);

        // Build the RMIP structure
        m_rmipBuilder.buildRMIP(cmd, displacementImage, displacementView,
            rmipData.image.image, rmipData.view, resolution);

        // Store the RMIP and factor for later use
        rmipData.displacementFactor = displacementFactor;  // Store the scale factor
        rmipData.texCoord = displacement.displacementGeometryTexture.texCoord;
        rmipData.displacementTextureIndex = static_cast<uint32_t>(textureIdx);
        rmipData.maxDisplacement = displacement.displacementGeometryFactor;
        rmipData.hasDisplacement = true;
        m_displacementRMIPs[static_cast<int>(matIdx)] = rmipData;

        LOGI("Built RMIP for material %zu '%s', displacement map %d (%dx%d, %d layers, factor=%.3f)\n",
            matIdx, material.name.c_str(), imageIdx, resolution, resolution, numLayers, displacementFactor);
    }

    passRMIPToPathTracer();
}

void GltfRenderer::cleanupDisplacementRMIPs()
{
    for (auto& rmip : m_displacementRMIPs)
    {
        if (rmip.view != VK_NULL_HANDLE)
        {
            vkDestroyImageView(m_device, rmip.view, nullptr);
            rmip.view = VK_NULL_HANDLE;
        }
        if (rmip.image.image != VK_NULL_HANDLE)
        {
            m_resources.allocator.destroyImage(rmip.image);
        }
        rmip = RmipData{};  // Reset to default
    }
    m_displacementRMIPs.clear();
}

// ADD: Pass RMIP data to PathTracer
void GltfRenderer::passRMIPToPathTracer()
{
    // Convert RmipData to PathTracer::DisplacementInfo
    std::vector<PathTracer::DisplacementInfo> displacementInfo;
    displacementInfo.reserve(m_displacementRMIPs.size());

    // Build material-to-displacement-index mapping
    // Maps materialID -> index in the 8-element displacement texture arrays
    // -1 means no displacement for this material
    std::vector<int32_t> materialToDispIndex(m_displacementRMIPs.size(), -1);
    std::vector<float> displacementFactors;  // Only for materials WITH displacement
    int32_t dispIdx = 0;

    for (size_t i = 0; i < m_displacementRMIPs.size(); ++i)
    {
        const auto& rmip = m_displacementRMIPs[i];

        PathTracer::DisplacementInfo info;
        info.hasDisplacement = rmip.hasDisplacement;
        info.rmipView = rmip.view;
        info.rmipTextureIndex = static_cast<uint32_t>(i);  // Index in the array
        info.displacementTextureIndex = rmip.displacementTextureIndex;
        info.maxDisplacement = rmip.maxDisplacement * rmip.displacementFactor;

        displacementInfo.push_back(info);

        // Build mapping for materials WITH displacement
        if (rmip.hasDisplacement)
        {
            materialToDispIndex[i] = dispIdx;
            displacementFactors.push_back(rmip.displacementFactor);
            dispIdx++;
        }
    }

    // Create/update displacement factors buffer (now indexed by dispIdx, not materialID)
    if (m_resources.bDisplacementFactors.buffer != VK_NULL_HANDLE)
    {
        m_resources.allocator.destroyBuffer(m_resources.bDisplacementFactors);
    }

    if (!displacementFactors.empty())
    {
        VkDeviceSize bufferSize = displacementFactors.size() * sizeof(float);
        NVVK_CHECK(m_resources.allocator.createBuffer(m_resources.bDisplacementFactors, bufferSize,
                                                      VK_BUFFER_USAGE_2_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_2_TRANSFER_DST_BIT,
                                                      VMA_MEMORY_USAGE_GPU_ONLY));
        NVVK_DBG_NAME(m_resources.bDisplacementFactors.buffer);

        LOGI("Created displacement factors buffer with %zu entries\n", displacementFactors.size());
    }

    // Create/update material-to-displacement-index mapping buffer
    if (m_resources.bMaterialDispIndex.buffer != VK_NULL_HANDLE)
    {
        m_resources.allocator.destroyBuffer(m_resources.bMaterialDispIndex);
    }

    if (!materialToDispIndex.empty())
    {
        VkDeviceSize mappingBufferSize = materialToDispIndex.size() * sizeof(int32_t);
        NVVK_CHECK(m_resources.allocator.createBuffer(m_resources.bMaterialDispIndex, mappingBufferSize,
                                                      VK_BUFFER_USAGE_2_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_2_TRANSFER_DST_BIT,
                                                      VMA_MEMORY_USAGE_GPU_ONLY));
        NVVK_DBG_NAME(m_resources.bMaterialDispIndex.buffer);

        LOGI("Created material-to-disp-index mapping buffer with %zu entries\n", materialToDispIndex.size());
    }

    // Upload both buffers using staging
    if (!displacementFactors.empty() || !materialToDispIndex.empty())
    {
        VkCommandBuffer cmd{};
        nvvk::beginSingleTimeCommands(cmd, m_device, m_transientCmdPool);

        if (!displacementFactors.empty())
        {
            VkDeviceSize bufferSize = displacementFactors.size() * sizeof(float);
            m_resources.staging.appendBuffer(m_resources.bDisplacementFactors, 0, bufferSize, displacementFactors.data());
        }
        if (!materialToDispIndex.empty())
        {
            VkDeviceSize mappingBufferSize = materialToDispIndex.size() * sizeof(int32_t);
            m_resources.staging.appendBuffer(m_resources.bMaterialDispIndex, 0, mappingBufferSize, materialToDispIndex.data());
        }

        m_resources.staging.cmdUploadAppended(cmd);
        nvvk::endSingleTimeCommands(cmd, m_device, m_transientCmdPool, m_app->getQueue(0).queue);
    }

    // Pass to PathTracer
    m_pathTracer.setDisplacementData(displacementInfo);
}

// Update displacement factors from the glTF model when material properties change
// This is called when the user edits displacement factor/offset in the GUI
void GltfRenderer::updateDisplacementFactors(VkCommandBuffer cmd)
{
    if (m_displacementRMIPs.empty())
        return;

    const tinygltf::Model& model = m_resources.scene.getModel();

    // Gather updated displacement factors from the tinygltf model
    std::vector<float> displacementFactors;
    bool anyChanges = false;

    for (size_t matIdx = 0; matIdx < m_displacementRMIPs.size(); ++matIdx)
    {
        RmipData& rmip = m_displacementRMIPs[matIdx];
        if (!rmip.hasDisplacement)
            continue;

        if (matIdx < model.materials.size())
        {
            const tinygltf::Material& material = model.materials[matIdx];
            KHR_materials_displacement displacement = tinygltf::utils::getDisplacement(material);

            // Check if the factor changed
            if (rmip.displacementFactor != displacement.displacementGeometryFactor)
            {
                rmip.displacementFactor = displacement.displacementGeometryFactor;
                anyChanges = true;
            }
        }

        displacementFactors.push_back(rmip.displacementFactor);
    }

    // Only update buffer if something changed
    if (anyChanges && !displacementFactors.empty() && m_resources.bDisplacementFactors.buffer != VK_NULL_HANDLE)
    {
        VkDeviceSize bufferSize = displacementFactors.size() * sizeof(float);
        m_resources.staging.appendBuffer(m_resources.bDisplacementFactors, 0, bufferSize, displacementFactors.data());
    }
}


