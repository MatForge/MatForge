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

    // Normalize vertex normals (in case they aren't normalized)
    float3 nn0 = normalize(n0);
    float3 nn1 = normalize(n1);
    float3 nn2 = normalize(n2);

    // Method 2: Normal-aware expansion (accurate, tight bounds)
    // Compute displaced vertex positions at min and max displacement
    // This creates much tighter AABBs than uniform expansion
    float3 d0_min = v0 + nn0 * params.minDisplacement;
    float3 d0_max = v0 + nn0 * params.maxDisplacement;
    float3 d1_min = v1 + nn1 * params.minDisplacement;
    float3 d1_max = v1 + nn1 * params.maxDisplacement;
    float3 d2_min = v2 + nn2 * params.minDisplacement;
    float3 d2_max = v2 + nn2 * params.maxDisplacement;

    // Compute AABB of all displaced vertex positions (6 points total)
    float3 minBounds = min(min(min(min(min(d0_min, d0_max), d1_min), d1_max), d2_min), d2_max);
    float3 maxBounds = max(max(max(max(max(d0_min, d0_max), d1_min), d1_max), d2_min), d2_max);

    // Add a small epsilon for numerical stability and to account for
    // displacement variations within the triangle (not just at vertices)
    float epsilon = 0.001;
    minBounds -= float3(epsilon, epsilon, epsilon);
    maxBounds += float3(epsilon, epsilon, epsilon);

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
