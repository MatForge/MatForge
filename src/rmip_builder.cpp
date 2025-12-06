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

    createDescriptorSetLayouts();  // V38: Now creates separate layouts
    createPipelines();

    // Create descriptor pool - V38: Need pool sizes for both init and expand bindings
    std::vector<VkDescriptorPoolSize> initPoolSizes = m_initBindings.calculatePoolSizes();
    std::vector<VkDescriptorPoolSize> expandPoolSizes = m_expandBindings.calculatePoolSizes();

    // Combine pool sizes (may have duplicates, but that's fine - we just need enough)
    std::vector<VkDescriptorPoolSize> poolSizes;
    poolSizes.insert(poolSizes.end(), initPoolSizes.begin(), initPoolSizes.end());
    poolSizes.insert(poolSizes.end(), expandPoolSizes.begin(), expandPoolSizes.end());

    VkDescriptorPoolCreateInfo        poolInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = 200,  // V38: Double the sets since we have two layouts now
        .poolSizeCount = uint32_t(poolSizes.size()),
        .pPoolSizes = poolSizes.data(),
    };
    NVVK_CHECK(vkCreateDescriptorPool(m_device, &poolInfo, nullptr, &m_descriptorPool));
    NVVK_DBG_NAME(m_descriptorPool);

    // Create reusable params buffer (to avoid creating/leaking one per dispatch)
    NVVK_CHECK(m_allocator->createBuffer(
        m_paramsBuffer,
        sizeof(RmipBuildParams),
        VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        VMA_MEMORY_USAGE_CPU_TO_GPU,
        VMA_ALLOCATION_CREATE_MAPPED_BIT | VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT));
    NVVK_DBG_NAME(m_paramsBuffer.buffer);
}

//--------------------------------------------------------------------------------------------------
// Cleanup all resources
//
void RmipBuilder::deinit()
{
    // Early exit if not initialized
    if (m_device == VK_NULL_HANDLE || m_allocator == nullptr)
        return;

    // Destroy staging image view (owned by RmipBuilder)
    if (m_stagingView != VK_NULL_HANDLE)
        vkDestroyImageView(m_device, m_stagingView, nullptr);

    // NOTE: m_rmipView is NOT destroyed here - it's an external view provided by the caller!
    // The caller is responsible for destroying it.

    // Destroy staging image (owned by RmipBuilder)
    if (m_stagingImage.image != VK_NULL_HANDLE)
        m_allocator->destroyImage(m_stagingImage);

    // Destroy params buffer (owned by RmipBuilder)
    if (m_paramsBuffer.buffer != VK_NULL_HANDLE)
        m_allocator->destroyBuffer(m_paramsBuffer);

    // NOTE: m_rmipImage is NOT destroyed here - it's an external image provided by the caller!
    // At line 251 of buildRMIP(), we assign: m_rmipImage.image = rmipOutput (external)
    // The caller is responsible for destroying it.

    // Destroy pipelines and layouts - V38: Now have separate layouts for init and expand
    if (m_initPipeline != VK_NULL_HANDLE)
        vkDestroyPipeline(m_device, m_initPipeline, nullptr);
    if (m_expandPipeline != VK_NULL_HANDLE)
        vkDestroyPipeline(m_device, m_expandPipeline, nullptr);
    if (m_initPipelineLayout != VK_NULL_HANDLE)
        vkDestroyPipelineLayout(m_device, m_initPipelineLayout, nullptr);
    if (m_expandPipelineLayout != VK_NULL_HANDLE)
        vkDestroyPipelineLayout(m_device, m_expandPipelineLayout, nullptr);
    if (m_initDescriptorSetLayout != VK_NULL_HANDLE)
        vkDestroyDescriptorSetLayout(m_device, m_initDescriptorSetLayout, nullptr);
    if (m_expandDescriptorSetLayout != VK_NULL_HANDLE)
        vkDestroyDescriptorSetLayout(m_device, m_expandDescriptorSetLayout, nullptr);
    if (m_descriptorPool != VK_NULL_HANDLE)
        vkDestroyDescriptorPool(m_device, m_descriptorPool, nullptr);

    m_initBindings.clear();
    m_expandBindings.clear();

    // Reset all handles - V38: Updated for separate layouts
    m_device = VK_NULL_HANDLE;
    m_allocator = nullptr;
    m_stagingView = VK_NULL_HANDLE;
    m_rmipView = VK_NULL_HANDLE;  // External, don't destroy
    m_stagingImage = {};
    m_rmipImage = {};  // External, don't destroy
    m_paramsBuffer = {};
    m_initPipeline = VK_NULL_HANDLE;
    m_expandPipeline = VK_NULL_HANDLE;
    m_initPipelineLayout = VK_NULL_HANDLE;
    m_expandPipelineLayout = VK_NULL_HANDLE;
    m_initDescriptorSetLayout = VK_NULL_HANDLE;
    m_expandDescriptorSetLayout = VK_NULL_HANDLE;
    m_descriptorPool = VK_NULL_HANDLE;
}

//--------------------------------------------------------------------------------------------------
// Reset descriptor pool - call before building RMIPs for a new scene
// This frees all allocated descriptor sets, allowing the pool to be reused
//
void RmipBuilder::resetDescriptorPool()
{
    if (m_device == VK_NULL_HANDLE || m_descriptorPool == VK_NULL_HANDLE)
        return;

    // Reset the descriptor pool, freeing all allocated descriptor sets
    vkResetDescriptorPool(m_device, m_descriptorPool, 0);
}

//--------------------------------------------------------------------------------------------------
// Create descriptor set layouts for RMIP building
// V38: Now creates TWO separate layouts:
//   - Init shader: SAMPLED_IMAGE for binding 0 (reads displacement texture with sampler support)
//   - Expand shader: STORAGE_IMAGE for binding 0 (reads RMIP arrays with [] operator)
//
void RmipBuilder::createDescriptorSetLayouts()
{
    // ========================================
    // Init shader layout (SAMPLED_IMAGE for binding 0)
    // ========================================
    // Binding 0: Displacement texture (Texture2D) - SAMPLED_IMAGE
    m_initBindings.addBinding(0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT);
    // Binding 1: Output RMIP array (RWTexture2DArray) - STORAGE_IMAGE
    m_initBindings.addBinding(1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT);
    // Binding 2: Uniform buffer (parameters)
    m_initBindings.addBinding(2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT);

    NVVK_CHECK(m_initBindings.createDescriptorSetLayout(m_device, 0, &m_initDescriptorSetLayout));
    NVVK_DBG_NAME(m_initDescriptorSetLayout);

    // ========================================
    // Expand shader layout (STORAGE_IMAGE for binding 0)
    // ========================================
    // Binding 0: Input RMIP array (RWTexture2DArray for read) - STORAGE_IMAGE
    // V38 FIX: Must be STORAGE_IMAGE to support [] operator in Slang shader
    m_expandBindings.addBinding(0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT);
    // Binding 1: Output RMIP array (RWTexture2DArray for write) - STORAGE_IMAGE
    m_expandBindings.addBinding(1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT);
    // Binding 2: Uniform buffer (parameters)
    m_expandBindings.addBinding(2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT);

    NVVK_CHECK(m_expandBindings.createDescriptorSetLayout(m_device, 0, &m_expandDescriptorSetLayout));
    NVVK_DBG_NAME(m_expandDescriptorSetLayout);
}

//--------------------------------------------------------------------------------------------------
// Create compute pipelines for RMIP construction
// V38: Now creates separate pipeline layouts for init and expand
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

    // Init pipeline layout (uses init descriptor set layout)
    VkPipelineLayoutCreateInfo initLayoutInfo{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &m_initDescriptorSetLayout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &pushConstant,
    };
    NVVK_CHECK(vkCreatePipelineLayout(m_device, &initLayoutInfo, nullptr, &m_initPipelineLayout));
    NVVK_DBG_NAME(m_initPipelineLayout);

    // Expand pipeline layout (uses expand descriptor set layout)
    VkPipelineLayoutCreateInfo expandLayoutInfo{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &m_expandDescriptorSetLayout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &pushConstant,
    };
    NVVK_CHECK(vkCreatePipelineLayout(m_device, &expandLayoutInfo, nullptr, &m_expandPipelineLayout));
    NVVK_DBG_NAME(m_expandPipelineLayout);

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

    // Create init pipeline
    VkPipelineShaderStageCreateInfo initShaderStage{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_COMPUTE_BIT,
        .module = initModule,
        .pName = "main",
    };

    VkComputePipelineCreateInfo initPipelineInfo{
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = initShaderStage,
        .layout = m_initPipelineLayout,  // V38: Uses init-specific layout
    };

    NVVK_CHECK(vkCreateComputePipelines(m_device, VK_NULL_HANDLE, 1, &initPipelineInfo, nullptr, &m_initPipeline));
    NVVK_DBG_NAME(m_initPipeline);

    // Create expand pipeline
    VkPipelineShaderStageCreateInfo expandShaderStage{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_COMPUTE_BIT,
        .module = expandModule,
        .pName = "main",
    };

    VkComputePipelineCreateInfo expandPipelineInfo{
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = expandShaderStage,
        .layout = m_expandPipelineLayout,  // V38: Uses expand-specific layout
    };

    NVVK_CHECK(vkCreateComputePipelines(m_device, VK_NULL_HANDLE, 1, &expandPipelineInfo, nullptr, &m_expandPipeline));
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

    // Transition staging image from UNDEFINED to GENERAL
    transitionToGeneral(cmd, m_stagingImage.image);

    // Transition RMIP output image from UNDEFINED to GENERAL
    transitionToGeneral(cmd, rmipOutput);

    // Store RMIP output for later use (these are external resources, don't destroy old ones)
    // NOTE: m_rmipImage and m_rmipView are external - provided by caller
    // We just store references to them, we don't own them
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
        // V38: Use init-specific bind function (SAMPLED_IMAGE for displacement map)
        bindInitResources(cmd, displacementView, rmipOutputView, params);

        uint32_t groupsX = (resolution + 15) / 16;
        uint32_t groupsY = (resolution + 15) / 16;
        vkCmdDispatch(cmd, groupsX, groupsY, 1);

        addImageBarrier(cmd, rmipOutput);
    }

    // Step 2: Build all other levels
    // FIX V37e: Vulkan doesn't allow same image for SAMPLED_IMAGE + STORAGE_IMAGE in same dispatch
    // Solution: Use ping-pong but copy ALL layers after each level so both buffers have all data

    // First copy layer 0 from rmipOutput to staging so both have the base data
    {
        VkImageCopy copyRegion{
            .srcSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = numLayers},
            .dstSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = numLayers},
            .extent = {resolution, resolution, 1},
        };
        vkCmdCopyImage(cmd, rmipOutput, VK_IMAGE_LAYOUT_GENERAL,
            m_stagingImage.image, VK_IMAGE_LAYOUT_GENERAL, 1, &copyRegion);
        // V38b: Use transfer barrier after copy
        addTransferBarrier(cmd, m_stagingImage.image);
    }

    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, m_expandPipeline);

    // Track which buffer has the latest data
    VkImage     currentInput = rmipOutput;
    VkImageView currentInputView = rmipOutputView;
    VkImage     currentOutput = m_stagingImage.image;
    VkImageView currentOutputView = m_stagingView;

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

            // V38: Use expand-specific bind function (STORAGE_IMAGE for RMIP arrays)
            bindExpandResources(cmd, currentInputView, currentOutputView, params);

            uint32_t width = 1u << p;
            uint32_t height = 1u << q;
            uint32_t maxPosX = resolution - width + 1;
            uint32_t maxPosY = resolution - height + 1;
            uint32_t groupsX = (maxPosX + 15) / 16;
            uint32_t groupsY = (maxPosY + 15) / 16;

            vkCmdDispatch(cmd, groupsX, groupsY, 1);
            addImageBarrier(cmd, currentOutput);
        }

        // After each level, copy ALL layers from output back to input
        // This ensures both buffers have all layers for the next level
        {
            VkImageCopy copyRegion{
                .srcSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = numLayers},
                .dstSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = numLayers},
                .extent = {resolution, resolution, 1},
            };
            vkCmdCopyImage(cmd, currentOutput, VK_IMAGE_LAYOUT_GENERAL,
                currentInput, VK_IMAGE_LAYOUT_GENERAL, 1, &copyRegion);
            // V38b: Use transfer barrier after copy
            addTransferBarrier(cmd, currentInput);
        }

        // Swap buffers for next level
        std::swap(currentInput, currentOutput);
        std::swap(currentInputView, currentOutputView);
    }

    // Copy final result to rmipOutput if needed
    if (currentInput != rmipOutput)
    {
        VkImageCopy copyRegion{
            .srcSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = numLayers},
            .dstSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .layerCount = numLayers},
            .extent = {resolution, resolution, 1},
        };
        vkCmdCopyImage(cmd, currentInput, VK_IMAGE_LAYOUT_GENERAL,
            rmipOutput, VK_IMAGE_LAYOUT_GENERAL, 1, &copyRegion);
        // V38b: Barrier so shaders can read the final result
        addTransferBarrier(cmd, rmipOutput);
    }

    LOGI("RMIP built: %dx%d, %d layers\n", resolution, resolution, numLayers);
}

//--------------------------------------------------------------------------------------------------
// Bind resources for init shader dispatch
// V38: Uses init-specific descriptor layout (SAMPLED_IMAGE for binding 0)
//
void RmipBuilder::bindInitResources(VkCommandBuffer cmd,
    VkImageView           inputView,
    VkImageView           outputView,
    const RmipBuildParams& params)
{
    // Allocate descriptor set from init layout
    VkDescriptorSetAllocateInfo allocInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = m_descriptorPool,
        .descriptorSetCount = 1,
        .pSetLayouts = &m_initDescriptorSetLayout,
    };

    VkDescriptorSet descriptorSet;
    NVVK_CHECK(vkAllocateDescriptorSets(m_device, &allocInfo, &descriptorSet));

    // Update the reusable params buffer with new data
    memcpy(m_paramsBuffer.mapping, &params, sizeof(RmipBuildParams));

    // Update descriptor set
    VkDescriptorImageInfo inputImageInfo{
        .imageView = inputView,
        .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,  // Displacement map is SHADER_READ_ONLY
    };

    VkDescriptorImageInfo outputImageInfo{
        .imageView = outputView,
        .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
    };

    VkDescriptorBufferInfo bufferInfo{
        .buffer = m_paramsBuffer.buffer,
        .offset = 0,
        .range = sizeof(RmipBuildParams),
    };

    nvvk::WriteSetContainer writes;
    writes.append(m_initBindings.getWriteSet(0, descriptorSet), inputImageInfo);
    writes.append(m_initBindings.getWriteSet(1, descriptorSet), outputImageInfo);
    writes.append(m_initBindings.getWriteSet(2, descriptorSet), bufferInfo);

    vkUpdateDescriptorSets(m_device, writes.size(), writes.data(), 0, nullptr);

    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, m_initPipelineLayout,
        0, 1, &descriptorSet, 0, nullptr);

    vkCmdPushConstants(cmd, m_initPipelineLayout, VK_SHADER_STAGE_COMPUTE_BIT,
        0, sizeof(RmipBuildParams), &params);
}

//--------------------------------------------------------------------------------------------------
// Bind resources for expand shader dispatch
// V38: Uses expand-specific descriptor layout (STORAGE_IMAGE for binding 0)
//
void RmipBuilder::bindExpandResources(VkCommandBuffer cmd,
    VkImageView           inputView,
    VkImageView           outputView,
    const RmipBuildParams& params)
{
    // Allocate descriptor set from expand layout
    VkDescriptorSetAllocateInfo allocInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = m_descriptorPool,
        .descriptorSetCount = 1,
        .pSetLayouts = &m_expandDescriptorSetLayout,
    };

    VkDescriptorSet descriptorSet;
    NVVK_CHECK(vkAllocateDescriptorSets(m_device, &allocInfo, &descriptorSet));

    // Update the reusable params buffer with new data
    memcpy(m_paramsBuffer.mapping, &params, sizeof(RmipBuildParams));

    // Update descriptor set
    VkDescriptorImageInfo inputImageInfo{
        .imageView = inputView,
        .imageLayout = VK_IMAGE_LAYOUT_GENERAL,  // RMIP arrays are GENERAL for storage access
    };

    VkDescriptorImageInfo outputImageInfo{
        .imageView = outputView,
        .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
    };

    VkDescriptorBufferInfo bufferInfo{
        .buffer = m_paramsBuffer.buffer,
        .offset = 0,
        .range = sizeof(RmipBuildParams),
    };

    nvvk::WriteSetContainer writes;
    writes.append(m_expandBindings.getWriteSet(0, descriptorSet), inputImageInfo);
    writes.append(m_expandBindings.getWriteSet(1, descriptorSet), outputImageInfo);
    writes.append(m_expandBindings.getWriteSet(2, descriptorSet), bufferInfo);

    vkUpdateDescriptorSets(m_device, writes.size(), writes.data(), 0, nullptr);

    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, m_expandPipelineLayout,
        0, 1, &descriptorSet, 0, nullptr);

    vkCmdPushConstants(cmd, m_expandPipelineLayout, VK_SHADER_STAGE_COMPUTE_BIT,
        0, sizeof(RmipBuildParams), &params);
}

//--------------------------------------------------------------------------------------------------
// Add image memory barrier for compute shader writes
// V38b FIX: Now includes TRANSFER stage for copy operations
//
void RmipBuilder::addImageBarrier(VkCommandBuffer cmd, VkImage image)
{
    VkImageMemoryBarrier barrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        // V38b: Include TRANSFER access for copy operations
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .image = image,
        .subresourceRange = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                            .levelCount = VK_REMAINING_MIP_LEVELS,
                            .layerCount = VK_REMAINING_ARRAY_LAYERS},
    };

    // V38b: Include TRANSFER stage for vkCmdCopyImage operations
    vkCmdPipelineBarrier(cmd,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, nullptr, 0, nullptr, 1, &barrier);
}

//--------------------------------------------------------------------------------------------------
// Add barrier after transfer (copy) operations
// V38b: Ensures copy completes before next shader/transfer reads
//
void RmipBuilder::addTransferBarrier(VkCommandBuffer cmd, VkImage image)
{
    VkImageMemoryBarrier barrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .image = image,
        .subresourceRange = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                            .levelCount = VK_REMAINING_MIP_LEVELS,
                            .layerCount = VK_REMAINING_ARRAY_LAYERS},
    };

    vkCmdPipelineBarrier(cmd,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, nullptr, 0, nullptr, 1, &barrier);
}

//--------------------------------------------------------------------------------------------------
// Transition image from UNDEFINED to GENERAL layout
//
void RmipBuilder::transitionToGeneral(VkCommandBuffer cmd, VkImage image)
{
    VkImageMemoryBarrier barrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                            .levelCount = VK_REMAINING_MIP_LEVELS,
                            .layerCount = VK_REMAINING_ARRAY_LAYERS},
    };

    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0,
        0, nullptr, 0, nullptr, 1, &barrier);
}