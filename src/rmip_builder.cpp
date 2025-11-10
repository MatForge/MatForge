#include "rmip_builder.hpp"
#include <nvvk/check_error.hpp>
#include <nvvk/debug_util.hpp>
#include <nvvk/compute_pipeline.hpp>
#include <nvutils/timers.hpp>
#include <nvutils/logger.hpp>
#include <cmath>


#include "_autogen/rmip_init.compute.slang.h"
#include "_autogen/rmip_expand.compute.slang.h"

//--------------------------------------------------------------------------------------------------
// Initialize the RMIP builder with necessary Vulkan resources
//
void RmipBuilder::init(nvvk::ResourceAllocator& allocator, VkCommandPool commandPool)
{
    SCOPED_TIMER(__FUNCTION__);

    m_device = allocator.getDevice();
    m_allocator = &allocator;
    m_commandPool = commandPool;

    createDescriptorSetLayout();
    createPipelines();

    // Create descriptor pool
    std::vector<VkDescriptorPoolSize> poolSizes = m_bindings.calculatePoolSizes();
    VkDescriptorPoolCreateInfo        poolInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = 100,  // Allow many descriptor sets for multiple dispatches
        .poolSizeCount = uint32_t(poolSizes.size()),
        .pPoolSizes = poolSizes.data(),
    };
    NVVK_CHECK(vkCreateDescriptorPool(m_device, &poolInfo, nullptr, &m_descriptorPool));
    NVVK_DBG_NAME(m_descriptorPool);
}

//--------------------------------------------------------------------------------------------------
// Cleanup all resources
//
void RmipBuilder::deinit()
{
    if (m_stagingView)
        vkDestroyImageView(m_device, m_stagingView, nullptr);
    if (m_rmipView)
        vkDestroyImageView(m_device, m_rmipView, nullptr);

    m_allocator->destroyImage(m_stagingImage);
    m_allocator->destroyImage(m_rmipImage);

    vkDestroyPipeline(m_device, m_initPipeline, nullptr);
    vkDestroyPipeline(m_device, m_expandPipeline, nullptr);
    vkDestroyPipelineLayout(m_device, m_pipelineLayout, nullptr);
    vkDestroyDescriptorSetLayout(m_device, m_descriptorSetLayout, nullptr);
    vkDestroyDescriptorPool(m_device, m_descriptorPool, nullptr);

    m_bindings.clear();
    m_device = VK_NULL_HANDLE;
    m_allocator = nullptr;
    m_stagingView = VK_NULL_HANDLE;
    m_rmipView = VK_NULL_HANDLE;
}

//--------------------------------------------------------------------------------------------------
// Create descriptor set layout for RMIP building
//
void RmipBuilder::createDescriptorSetLayout()
{
    // Binding 0: Input texture (Texture2D or Texture2DArray)
    m_bindings.addBinding(0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT);

    // Binding 1: Output texture (RWTexture2DArray)
    m_bindings.addBinding(1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT);

    // Binding 2: Uniform buffer (parameters)
    m_bindings.addBinding(2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT);

    NVVK_CHECK(m_bindings.createDescriptorSetLayout(m_device, 0, &m_descriptorSetLayout));
    NVVK_DBG_NAME(m_descriptorSetLayout);
}

//--------------------------------------------------------------------------------------------------
// Create compute pipelines for RMIP construction
//
void RmipBuilder::createPipelines()
{
    SCOPED_TIMER(__FUNCTION__);

    // Push constant for parameters
    VkPushConstantRange pushConstant{
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = sizeof(RmipBuildParams),
    };

    // Pipeline layout
    VkPipelineLayoutCreateInfo layoutInfo{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &m_descriptorSetLayout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &pushConstant,
    };
    NVVK_CHECK(vkCreatePipelineLayout(m_device, &layoutInfo, nullptr, &m_pipelineLayout));
    NVVK_DBG_NAME(m_pipelineLayout);

    // Create shader modules
    VkShaderModuleCreateInfo moduleInfo{ .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };

    // Init shader
    moduleInfo.codeSize = rmip_init_compute_slang_sizeInBytes;
    moduleInfo.pCode = rmip_init_compute_slang;
    VkShaderModule initModule;
    NVVK_CHECK(vkCreateShaderModule(m_device, &moduleInfo, nullptr, &initModule));

    // Expand shader
    moduleInfo.codeSize = rmip_expand_compute_slang_sizeInBytes;
    moduleInfo.pCode = rmip_expand_compute_slang;
    VkShaderModule expandModule;
    NVVK_CHECK(vkCreateShaderModule(m_device, &moduleInfo, nullptr, &expandModule));

    // Create pipelines
    VkPipelineShaderStageCreateInfo shaderStage{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_COMPUTE_BIT,
        .module = initModule,
        .pName = "main",
    };

    VkComputePipelineCreateInfo pipelineInfo{
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = shaderStage,
        .layout = m_pipelineLayout,
    };

    NVVK_CHECK(vkCreateComputePipelines(m_device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &m_initPipeline));
    NVVK_DBG_NAME(m_initPipeline);

    pipelineInfo.stage.module = expandModule;
    NVVK_CHECK(vkCreateComputePipelines(m_device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &m_expandPipeline));
    NVVK_DBG_NAME(m_expandPipeline);

    vkDestroyShaderModule(m_device, initModule, nullptr);
    vkDestroyShaderModule(m_device, expandModule, nullptr);
}

//--------------------------------------------------------------------------------------------------
// Create staging image for ping-pong during construction
//
void RmipBuilder::createStagingImage(uint32_t resolution, uint32_t numLayers)
{
    // Destroy old staging if it exists
    if (m_stagingView)
        vkDestroyImageView(m_device, m_stagingView, nullptr);
    m_allocator->destroyImage(m_stagingImage);

    // Create image
    VkImageCreateInfo imageInfo{
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R32G32_SFLOAT,  // (min, max) pair
        .extent = {resolution, resolution, 1},
        .mipLevels = 1,
        .arrayLayers = numLayers,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                         VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };

    NVVK_CHECK(m_allocator->createImage(m_stagingImage, imageInfo));
    NVVK_DBG_NAME(m_stagingImage.image);

    // Create image view
    VkImageViewCreateInfo viewInfo{
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = m_stagingImage.image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D_ARRAY,
        .format = VK_FORMAT_R32G32_SFLOAT,
        .subresourceRange = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = numLayers},
    };

    NVVK_CHECK(vkCreateImageView(m_device, &viewInfo, nullptr, &m_stagingView));
    NVVK_DBG_NAME(m_stagingView);
}

//--------------------------------------------------------------------------------------------------
// Build RMIP structure from displacement map
//
void RmipBuilder::buildRMIP(VkCommandBuffer cmd,
    VkImage         displacementMap,
    VkImageView     displacementView,
    VkImage         rmipOutput,
    VkImageView     rmipOutputView,
    uint32_t        resolution)
{
    NVVK_DBG_SCOPE(cmd);
    SCOPED_TIMER(__FUNCTION__);

    // Validate input
    if ((resolution & (resolution - 1)) != 0)
    {
        LOGE("RMIP: Resolution must be power of 2!\n");
        return;
    }

    uint32_t maxLevel = static_cast<uint32_t>(std::log2(resolution));
    uint32_t numLayers = (maxLevel + 1) * (maxLevel + 1);

    // Create staging for ping-pong
    createStagingImage(resolution, numLayers);

    // Store RMIP output for later use
    if (m_rmipView)
        vkDestroyImageView(m_device, m_rmipView, nullptr);
    m_allocator->destroyImage(m_rmipImage);

    m_rmipImage.image = rmipOutput;
    m_rmipView = rmipOutputView;

    // Step 1: Initialize base level (p=0, q=0)
    {
        RmipBuildParams params{};
        params.inputResolution[0] = resolution;
        params.inputResolution[1] = resolution;
        params.maxLevel = maxLevel;
        params.currentP = 0;
        params.currentQ = 0;

        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, m_initPipeline);
        bindResources(cmd, displacementView, rmipOutputView, params);

        uint32_t groupsX = (resolution + 15) / 16;
        uint32_t groupsY = (resolution + 15) / 16;
        vkCmdDispatch(cmd, groupsX, groupsY, 1);

        addImageBarrier(cmd, rmipOutput);
    }

    // Step 2: Build all other levels
    VkImage     currentInput = rmipOutput;
    VkImageView currentInputView = rmipOutputView;
    VkImage     currentOutput = m_stagingImage.image;
    VkImageView currentOutputView = m_stagingView;

    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, m_expandPipeline);

    // Process level by level
    for (uint32_t level = 1; level <= 2 * maxLevel; ++level)
    {
        for (uint32_t p = 0; p <= maxLevel && p <= level; ++p)
        {
            uint32_t q = level - p;
            if (q > maxLevel)
                continue;

            RmipBuildParams params{};
            params.inputResolution[0] = resolution;
            params.inputResolution[1] = resolution;
            params.maxLevel = maxLevel;
            params.currentP = p;
            params.currentQ = q;

            bindResources(cmd, currentInputView, currentOutputView, params);

            uint32_t width = 1u << p;
            uint32_t height = 1u << q;
            uint32_t maxPosX = resolution - width + 1;
            uint32_t maxPosY = resolution - height + 1;
            uint32_t groupsX = (maxPosX + 15) / 16;
            uint32_t groupsY = (maxPosY + 15) / 16;

            vkCmdDispatch(cmd, groupsX, groupsY, 1);
            addImageBarrier(cmd, currentOutput);
        }

        // Ping-pong buffers
        std::swap(currentInput, currentOutput);
        std::swap(currentInputView, currentOutputView);
    }

    // Copy final result back if needed
    if (currentInput == m_stagingImage.image)
    {
        VkImageCopy copyRegion{
            .srcSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = numLayers},
            .dstSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = numLayers},
            .extent = {resolution, resolution, 1},
        };
        vkCmdCopyImage(cmd, m_stagingImage.image, VK_IMAGE_LAYOUT_GENERAL,
            rmipOutput, VK_IMAGE_LAYOUT_GENERAL, 1, &copyRegion);
    }

    LOGI("RMIP built: %dx%d, %d layers\n", resolution, resolution, numLayers);
}

//--------------------------------------------------------------------------------------------------
// Bind resources for a compute dispatch
//
void RmipBuilder::bindResources(VkCommandBuffer       cmd,
    VkImageView           inputView,
    VkImageView           outputView,
    const RmipBuildParams& params)
{
    // Allocate descriptor set
    VkDescriptorSetAllocateInfo allocInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = m_descriptorPool,
        .descriptorSetCount = 1,
        .pSetLayouts = &m_descriptorSetLayout,
    };

    VkDescriptorSet descriptorSet;
    NVVK_CHECK(vkAllocateDescriptorSets(m_device, &allocInfo, &descriptorSet));

    // Create uniform buffer for parameters
    nvvk::Buffer paramsBuffer;
    NVVK_CHECK(m_allocator->createBuffer(
        paramsBuffer,
        sizeof(RmipBuildParams),
        VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        VMA_MEMORY_USAGE_CPU_TO_GPU,
        VMA_ALLOCATION_CREATE_MAPPED_BIT | VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT));

    // Copy data using the mapped pointer from VMA
    memcpy(paramsBuffer.mapping, &params, sizeof(RmipBuildParams));

    // Update descriptor set
    VkDescriptorImageInfo inputImageInfo{
        .imageView = inputView,
        .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    VkDescriptorImageInfo outputImageInfo{
        .imageView = outputView,
        .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
    };

    VkDescriptorBufferInfo bufferInfo{
        .buffer = paramsBuffer.buffer,
        .offset = 0,
        .range = sizeof(RmipBuildParams),
    };

    nvvk::WriteSetContainer writes;
    writes.append(m_bindings.getWriteSet(0, descriptorSet), inputImageInfo);
    writes.append(m_bindings.getWriteSet(1, descriptorSet), outputImageInfo);
    writes.append(m_bindings.getWriteSet(2, descriptorSet), bufferInfo);

    vkUpdateDescriptorSets(m_device, writes.size(), writes.data(), 0, nullptr);

    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, m_pipelineLayout,
        0, 1, &descriptorSet, 0, nullptr);

    vkCmdPushConstants(cmd, m_pipelineLayout, VK_SHADER_STAGE_COMPUTE_BIT,
        0, sizeof(RmipBuildParams), &params);

}

//--------------------------------------------------------------------------------------------------
// Add image memory barrier
//
void RmipBuilder::addImageBarrier(VkCommandBuffer cmd, VkImage image)
{
    VkImageMemoryBarrier barrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .image = image,
        .subresourceRange = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                            .levelCount = VK_REMAINING_MIP_LEVELS,
                            .layerCount = VK_REMAINING_ARRAY_LAYERS},
    };

    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0,
        0, nullptr, 0, nullptr, 1, &barrier);
}