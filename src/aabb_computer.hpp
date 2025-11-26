/*
 * AABB Computer for Displacement Mapping
 *
 * Computes axis-aligned bounding boxes for displaced triangles using a GPU compute shader.
 * Used for RMIP displacement mapping BLAS creation.
 *
 * MatForge - CIS 5650 Fall 2025
 */

#pragma once

#include <vulkan/vulkan_core.h>
#include <nvvk/resource_allocator.hpp>
#include <nvvk/descriptors.hpp>

// Parameters for AABB computation
struct AabbComputeParams
{
    uint32_t numTriangles;
    float    minDisplacement;
    float    maxDisplacement;
    uint32_t padding;
};

class AabbComputer
{
public:
    AabbComputer() = default;
    ~AabbComputer() { assert(m_pipeline == VK_NULL_HANDLE && "Must call deinit()"); }

    // Initialize the AABB computer
    void init(VkDevice device, nvvk::ResourceAllocator* allocator);

    // Cleanup resources
    void deinit();

    // Compute AABBs for a primitive
    // This dispatches a compute shader that reads vertex/normal/index buffers
    // and writes AABBs to the output buffer
    void computeAABBs(VkCommandBuffer         cmd,
                      const nvvk::Buffer&     vertexBuffer,
                      const nvvk::Buffer&     normalBuffer,
                      const nvvk::Buffer&     indexBuffer,
                      const nvvk::Buffer&     aabbBuffer,
                      const AabbComputeParams& params);

private:
    void createPipeline();
    void createDescriptorSetLayout();

    VkDevice                 m_device{};
    nvvk::ResourceAllocator* m_allocator{};

    // Compute pipeline
    VkPipeline       m_pipeline{};
    VkPipelineLayout m_pipelineLayout{};

    // Descriptor management
    nvvk::DescriptorBindings m_bindings;
    VkDescriptorSetLayout    m_descriptorSetLayout{};
    VkDescriptorPool         m_descriptorPool{};
};
