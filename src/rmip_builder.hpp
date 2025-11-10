#pragma once

//////////////////////////////////////////////////////////////////////////
/*
    RMIP (Rectangular MinMax Image Pyramid) Builder

    This module implements GPU-accelerated construction of the RMIP data structure
    for efficient displacement mapping ray tracing. Key features include:

    - Hierarchical min-max pyramid construction for arbitrary rectangular queries
    - GPU compute shader implementation for fast building (~5ms for 4K maps)
    - Support for power-of-two texture resolutions
    - Memory-efficient storage with compression
    - Fractional LOD support for smooth transitions
    - Tiled displacement map support

    The RMIP structure enables constant-time range queries over rectangular regions
    in displacement texture space, which is critical for the displacement ray tracing
    method described in the paper "RMIP: Displacement ray-tracing via inversion and
    oblong bounding" (SIGGRAPH Asia 2023).
*/
//////////////////////////////////////////////////////////////////////////

#include <vulkan/vulkan_core.h>
#include <nvvk/resource_allocator.hpp>
#include <nvvk/descriptors.hpp>

// RMIP construction parameters
struct RmipBuildParams
{
    uint32_t inputResolution[2];  // N x N (power of 2)
    uint32_t maxLevel;             // log2(N)
    uint32_t currentP;             // Current p dimension being built
    uint32_t currentQ;             // Current q dimension being built
    uint32_t padding[3];
};

// RMIP Builder class
class RmipBuilder
{
public:
    RmipBuilder() = default;
    ~RmipBuilder() { assert(!m_initPipeline && "deinit must be called"); }

    // Initialize the RMIP builder
    void init(nvvk::ResourceAllocator& allocator, VkCommandPool commandPool);

    // Cleanup resources
    void deinit();

    // Build RMIP structure from a displacement map
    // This queues multiple compute dispatches that will be executed asynchronously
    void buildRMIP(VkCommandBuffer            cmd,
        VkImage                    displacementMap,
        VkImageView                displacementView,
        VkImage                    rmipOutput,
        VkImageView                rmipOutputView,
        uint32_t                   resolution);

    // Get the RMIP image and view (after building)
    VkImage     getRmipImage() const { return m_rmipImage.image; }
    VkImageView getRmipView() const { return m_rmipView; }

private:
    void createPipelines();
    void createDescriptorSetLayout();
    void createStagingImage(uint32_t resolution, uint32_t numLayers);
    void bindResources(VkCommandBuffer       cmd,
        VkImageView           inputView,
        VkImageView           outputView,
        const RmipBuildParams& params);
    void addImageBarrier(VkCommandBuffer cmd, VkImage image);

    VkDevice                  m_device{};
    nvvk::ResourceAllocator* m_allocator{};
    VkCommandPool             m_commandPool{};

    // Pipelines
    VkPipelineLayout m_pipelineLayout{};
    VkPipeline       m_initPipeline{};      // Initialize base level
    VkPipeline       m_expandPipeline{};    // Expand levels (unified)

    // Descriptor management
    nvvk::DescriptorBindings m_bindings;
    VkDescriptorSetLayout    m_descriptorSetLayout{};
    VkDescriptorPool         m_descriptorPool{};

    // Staging resources for ping-pong
    nvvk::Image   m_stagingImage{};
    VkImageView   m_stagingView{};

    // Output RMIP
    nvvk::Image m_rmipImage{};
    VkImageView m_rmipView{};
};
