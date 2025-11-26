/*
 * Compute Shader for Displacement AABB Generation
 *
 * This shader generates axis-aligned bounding boxes (AABBs) for displaced triangles.
 * Each triangle gets its own AABB, expanded by the displacement range along the surface normal.
 *
 * For RMIP displacement mapping in MatForge (CIS 5650 Fall 2025)
 */

#include "shaderio.h"

// Input: Vertex positions
[[vk::binding(0, 0)]]
StructuredBuffer<float3> vertexPositions;

// Input: Vertex normals
[[vk::binding(1, 0)]]
StructuredBuffer<float3> vertexNormals;

// Input: Triangle indices
[[vk::binding(2, 0)]]
StructuredBuffer<uint> indices;

// Output: AABBs (one per triangle)
[[vk::binding(3, 0)]]
RWStructuredBuffer<VkAabbPositionsKHR> aabbs;

// Parameters
struct AabbComputeParams
{
    uint numTriangles;
    float minDisplacement;  // Minimum displacement (typically 0 or negative)
    float maxDisplacement;  // Maximum displacement (scale factor)
    uint padding;
};

[[vk::push_constant]]
ConstantBuffer<AabbComputeParams> params;

// VkAabbPositionsKHR structure (matches Vulkan spec)
struct VkAabbPositionsKHR
{
    float minX;
    float minY;
    float minZ;
    float maxX;
    float maxY;
    float maxZ;
};

//-----------------------------------------------------------------------
// Compute AABB for a displaced triangle
//-----------------------------------------------------------------------
[shader("compute")]
[numthreads(256, 1, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint triangleIndex = dispatchThreadID.x;

    // Early exit if beyond triangle count
    if (triangleIndex >= params.numTriangles)
        return;

    // Get triangle vertex indices
    uint baseIndex = triangleIndex * 3;
    uint i0 = indices[baseIndex + 0];
    uint i1 = indices[baseIndex + 1];
    uint i2 = indices[baseIndex + 2];

    // Get vertex positions
    float3 v0 = vertexPositions[i0];
    float3 v1 = vertexPositions[i1];
    float3 v2 = vertexPositions[i2];

    // Get vertex normals
    float3 n0 = vertexNormals[i0];
    float3 n1 = vertexNormals[i1];
    float3 n2 = vertexNormals[i2];

    // Compute triangle bounds without displacement
    float3 minBounds = min(min(v0, v1), v2);
    float3 maxBounds = max(max(v0, v1), v2);

    // Expand bounds by displacement range along normals
    // For each vertex, displacement can push the surface along its normal

    // Method 1: Conservative - expand by max displacement in all directions
    // This is simple but may be overly conservative
    float maxExpansion = abs(params.maxDisplacement);
    float minExpansion = abs(params.minDisplacement);
    float expansion = max(maxExpansion, minExpansion);

    // Add a small epsilon for numerical stability
    expansion += 0.001;

    minBounds -= float3(expansion, expansion, expansion);
    maxBounds += float3(expansion, expansion, expansion);

    // Method 2: Normal-aware expansion (more accurate)
    // Compute the maximum extent along each normal direction
    // This would be:
    // for each vertex i in {0, 1, 2}:
    //   displaced_min_i = vi + ni * minDisplacement
    //   displaced_max_i = vi + ni * maxDisplacement
    // Then compute AABB of all displaced positions

    // Uncomment for normal-aware expansion (more accurate but more complex):
    /*
    float3 d0_min = v0 + n0 * params.minDisplacement;
    float3 d0_max = v0 + n0 * params.maxDisplacement;
    float3 d1_min = v1 + n1 * params.minDisplacement;
    float3 d1_max = v1 + n1 * params.maxDisplacement;
    float3 d2_min = v2 + n2 * params.minDisplacement;
    float3 d2_max = v2 + n2 * params.maxDisplacement;

    // Compute AABB of all displaced vertex positions
    minBounds = min(min(min(min(min(d0_min, d0_max), d1_min), d1_max), d2_min), d2_max);
    maxBounds = max(max(max(max(max(d0_min, d0_max), d1_min), d1_max), d2_min), d2_max);
    */

    // Write AABB
    VkAabbPositionsKHR aabb;
    aabb.minX = minBounds.x;
    aabb.minY = minBounds.y;
    aabb.minZ = minBounds.z;
    aabb.maxX = maxBounds.x;
    aabb.maxY = maxBounds.y;
    aabb.maxZ = maxBounds.z;

    aabbs[triangleIndex] = aabb;
}
