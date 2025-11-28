/*
 * RMIP Displacement Mapping Custom Intersection Shader
 * HYBRID VERSION - Combines working base-triangle approach with hole fix
 * 
 * Strategy:
 * 1. First try base triangle intersection (fast, handles most cases)
 * 2. If that fails, do conservative prism march to catch grazing rays
 * 
 * This avoids the "nothing renders" problem by always having a fallback.
 */

#include "shaderio.h"
#include "nvshaders/gltf_scene_io.h.slang"
#include "nvshaders/gltf_vertex_access.h.slang"
#include "nvshaders/constants.h.slang"
#include "rmip_common.h.slang"

// RMIP Data Structure binding
[[vk::binding(8, 1)]] Texture2DArray<float2> rmipTextures[8];
[[vk::binding(9, 1)]] Texture2D<float> displacementMaps[8];
[[vk::binding(10, 1)]] SamplerState rmipSampler;
[[vk::binding(11, 1)]] SamplerState displacementSampler;

// Push constant for accessing scene data
[[vk::push_constant]] ConstantBuffer<PathtracePushConstant> pushConst;

// Constants
static const float DISPLACEMENT_SCALE = 0.5;
static const int MAX_MARCH_STEPS = 64;
static const int BISECTION_STEPS = 4;

//=======================================================================
// Pack UV for hit attributes
//=======================================================================
uint packUV(float2 uv)
{
    uint x = uint(saturate(uv.x) * 65535.0);
    uint y = uint(saturate(uv.y) * 65535.0);
    return (x << 16) | y;
}

//=======================================================================
// Ray-Triangle intersection (Möller-Trumbore)
//=======================================================================
bool rayTriangleHit(
    float3 rayOrigin, float3 rayDir,
    float3 v0, float3 v1, float3 v2,
    out float hitT, out float hitU, out float hitV)
{
    float3 edge1 = v1 - v0;
    float3 edge2 = v2 - v0;
    float3 h = cross(rayDir, edge2);
    float a = dot(edge1, h);
    
    if (abs(a) < 1e-8)
        return false;
    
    float f = 1.0 / a;
    float3 s = rayOrigin - v0;
    float u = f * dot(s, h);
    
    if (u < 0.0 || u > 1.0)
        return false;
    
    float3 q = cross(s, edge1);
    float v = f * dot(rayDir, q);
    
    if (v < 0.0 || u + v > 1.0)
        return false;
    
    float t = f * dot(edge2, q);
    
    if (t <= 0.0)
        return false;
    
    hitT = t;
    hitU = u;
    hitV = v;
    return true;
}

//=======================================================================
// Ray-AABB intersection
//=======================================================================
bool rayAABBHit(
    float3 rayOrigin, float3 rayDir,
    float3 boxMin, float3 boxMax,
    out float tNear, out float tFar)
{
    float3 invDir = 1.0 / rayDir;
    float3 t0 = (boxMin - rayOrigin) * invDir;
    float3 t1 = (boxMax - rayOrigin) * invDir;
    
    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);
    
    tNear = max(max(tMin.x, tMin.y), tMin.z);
    tFar = min(min(tMax.x, tMax.y), tMax.z);
    
    return tNear <= tFar && tFar > 0;
}

//=======================================================================
// Sample displacement texture
//=======================================================================
float sampleDisplacement(float2 uv, uint matIdx)
{
    return displacementMaps[matIdx].SampleLevel(displacementSampler, saturate(uv), 0).r;
}

//=======================================================================
// Compute displaced surface position at barycentric coordinates
//=======================================================================
void getDisplacedSurface(
    float3 bary,
    float3 v0, float3 v1, float3 v2,
    float3 n0, float3 n1, float3 n2,
    float2 uv0, float2 uv1, float2 uv2,
    uint matIdx,
    out float3 surfacePos,
    out float3 surfaceNormal,
    out float2 surfaceUV)
{
    // Interpolate UV
    surfaceUV = bary.x * uv0 + bary.y * uv1 + bary.z * uv2;
    
    // Interpolate base position and normal
    float3 basePos = bary.x * v0 + bary.y * v1 + bary.z * v2;
    surfaceNormal = normalize(bary.x * n0 + bary.y * n1 + bary.z * n2);
    
    // Sample and apply displacement
    float disp = sampleDisplacement(surfaceUV, matIdx) * DISPLACEMENT_SCALE;
    surfacePos = basePos + surfaceNormal * disp;
}

//=======================================================================
// Project point onto triangle plane (for approximate UV)
//=======================================================================
float3 projectToTriangle(float3 P, float3 v0, float3 v1, float3 v2)
{
    float3 e0 = v1 - v0;
    float3 e1 = v2 - v0;
    
    // Use robust Gram-Schmidt-like computation
    float3 n = cross(e0, e1);
    float area2 = dot(n, n);
    
    if (area2 < 1e-12)
        return float3(1.0/3.0, 1.0/3.0, 1.0/3.0);
    
    // Project P to plane
    float3 pv0 = P - v0;
    float dist = dot(pv0, n) / sqrt(area2);
    float3 projP = P - normalize(n) * dist;
    
    // Compute barycentric coords
    float3 e2 = projP - v0;
    float d00 = dot(e0, e0);
    float d01 = dot(e0, e1);
    float d11 = dot(e1, e1);
    float d20 = dot(e2, e0);
    float d21 = dot(e2, e1);
    
    float denom = d00 * d11 - d01 * d01;
    if (abs(denom) < 1e-12)
        return float3(1.0/3.0, 1.0/3.0, 1.0/3.0);
    
    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    float u = 1.0 - v - w;
    
    return float3(u, v, w);
}

//=======================================================================
// Clamp barycentric coordinates to valid triangle
//=======================================================================
float3 clampBary(float3 bary)
{
    bary = max(float3(0), bary);
    float sum = bary.x + bary.y + bary.z;
    return sum > 1e-6 ? bary / sum : float3(1.0/3.0, 1.0/3.0, 1.0/3.0);
}

//=======================================================================
// Check if ray point is "inside" the displacement shell
// Returns signed distance: negative = inside, positive = outside
//=======================================================================
float signedDistanceToSurface(
    float3 rayPoint,
    float3 v0, float3 v1, float3 v2,
    float3 n0, float3 n1, float3 n2,
    float2 uv0, float2 uv1, float2 uv2,
    uint matIdx)
{
    // Project ray point to base triangle
    float3 bary = projectToTriangle(rayPoint, v0, v1, v2);
    bary = clampBary(bary);
    
    // Get displaced surface at this location
    float3 surfacePos, surfaceNormal;
    float2 surfaceUV;
    getDisplacedSurface(bary, v0, v1, v2, n0, n1, n2, uv0, uv1, uv2, matIdx,
                        surfacePos, surfaceNormal, surfaceUV);
    
    // Signed distance: positive if ray point is "above" surface (in normal direction)
    return dot(rayPoint - surfacePos, surfaceNormal);
}

//=======================================================================
// MAIN INTERSECTION SHADER
//=======================================================================
[shader("intersection")]
void intersectionMain()
{
    // Get ray information
    float3 rayOrigin = ObjectRayOrigin();
    float3 rayDir = ObjectRayDirection();
    float rayTMin = RayTMin();
    float rayTMax = RayTCurrent();
    
    // Get primitive information
    uint triangleIndex = PrimitiveIndex();
    uint instanceID = InstanceIndex();
    uint renderPrimID = InstanceID();
    
    // Access GLTF scene data
    GltfRenderNode* renderNodes = pushConst.gltfScene->renderNodes;
    GltfRenderPrimitive* renderPrimitives = pushConst.gltfScene->renderPrimitives;
    
    GltfRenderNode renderNode = renderNodes[instanceID];
    GltfRenderPrimitive renderPrim = renderPrimitives[renderPrimID];
    
    // Get material index
    int materialID = max(0, renderNode.materialID);
    uint matIdx = min(uint(materialID), 7u);
    
    // Get triangle indices
    uint3 indices = getTriangleIndices(renderPrim, triangleIndex);
    
    // Get vertex data
    float3 v0 = getVertexPosition(renderPrim, indices.x);
    float3 v1 = getVertexPosition(renderPrim, indices.y);
    float3 v2 = getVertexPosition(renderPrim, indices.z);
    
    float3 n0, n1, n2;
    if (hasVertexNormal(renderPrim))
    {
        n0 = getVertexNormal(renderPrim, indices.x);
        n1 = getVertexNormal(renderPrim, indices.y);
        n2 = getVertexNormal(renderPrim, indices.z);
    }
    else
    {
        float3 geoN = normalize(cross(v1 - v0, v2 - v0));
        n0 = n1 = n2 = geoN;
    }
    
    float2 uv0 = getInterpolatedVertexTexCoord0(renderPrim, indices, float3(1, 0, 0));
    float2 uv1 = getInterpolatedVertexTexCoord0(renderPrim, indices, float3(0, 1, 0));
    float2 uv2 = getInterpolatedVertexTexCoord0(renderPrim, indices, float3(0, 0, 1));
    
    // =====================================================================
    // APPROACH 1: Try base triangle intersection first (fast path)
    // =====================================================================
    float baseT, baseU, baseV;
    if (rayTriangleHit(rayOrigin, rayDir, v0, v1, v2, baseT, baseU, baseV))
    {
        if (baseT >= rayTMin && baseT <= rayTMax)
        {
            float baseW = 1.0 - baseU - baseV;
            float3 bary = float3(baseW, baseU, baseV);
            
            // Get displaced surface
            float3 surfacePos, surfaceNormal;
            float2 surfaceUV;
            getDisplacedSurface(bary, v0, v1, v2, n0, n1, n2, uv0, uv1, uv2, matIdx,
                                surfacePos, surfaceNormal, surfaceUV);
            
            // Compute new t for displaced position
            float newT = dot(surfacePos - rayOrigin, rayDir) / dot(rayDir, rayDir);
            
            if (newT >= rayTMin && newT <= rayTMax)
            {
                uint packedUV = packUV(surfaceUV);
                ReportHit(newT, 0, float2(asfloat(packedUV), 0.0));
                return;  // Fast path succeeded
            }
        }
    }
    
    // =====================================================================
    // APPROACH 2: Conservative prism march for grazing rays
    // This catches rays that miss the base triangle but hit the displaced surface
    // =====================================================================
    
    // Build conservative prism AABB
    float minDisp = 0.0;
    float maxDisp = DISPLACEMENT_SCALE;
    
    float3 v0_min = v0 + n0 * minDisp, v0_max = v0 + n0 * maxDisp;
    float3 v1_min = v1 + n1 * minDisp, v1_max = v1 + n1 * maxDisp;
    float3 v2_min = v2 + n2 * minDisp, v2_max = v2 + n2 * maxDisp;
    
    float3 boxMin = min(min(min(min(min(v0_min, v0_max), v1_min), v1_max), v2_min), v2_max);
    float3 boxMax = max(max(max(max(max(v0_min, v0_max), v1_min), v1_max), v2_min), v2_max);
    
    // Small expansion for numerical stability
    float3 expand = (boxMax - boxMin) * 0.01;
    boxMin -= expand;
    boxMax += expand;
    
    float tNear, tFar;
    if (!rayAABBHit(rayOrigin, rayDir, boxMin, boxMax, tNear, tFar))
        return;  // Ray misses prism entirely
    
    // Clamp to ray interval
    tNear = max(tNear, rayTMin);
    tFar = min(tFar, rayTMax);
    
    if (tNear >= tFar)
        return;
    
    // March through prism looking for surface crossing
    float stepSize = (tFar - tNear) / float(MAX_MARCH_STEPS);
    
    float t = tNear;
    float prevDist = signedDistanceToSurface(rayOrigin + rayDir * t,
                                              v0, v1, v2, n0, n1, n2, uv0, uv1, uv2, matIdx);
    
    for (int step = 1; step <= MAX_MARCH_STEPS; step++)
    {
        t = tNear + stepSize * float(step);
        if (t > tFar) break;
        
        float3 P = rayOrigin + rayDir * t;
        float dist = signedDistanceToSurface(P, v0, v1, v2, n0, n1, n2, uv0, uv1, uv2, matIdx);
        
        // Check for sign change (crossing)
        if (dist * prevDist < 0.0)
        {
            // Bisection refinement
            float tA = t - stepSize;
            float tB = t;
            
            for (int b = 0; b < BISECTION_STEPS; b++)
            {
                float tMid = (tA + tB) * 0.5;
                float3 PMid = rayOrigin + rayDir * tMid;
                float dMid = signedDistanceToSurface(PMid, v0, v1, v2, n0, n1, n2, uv0, uv1, uv2, matIdx);
                
                if (dMid * prevDist < 0.0)
                    tB = tMid;
                else
                    tA = tMid;
            }
            
            float hitT = (tA + tB) * 0.5;
            
            // Get final UV
            float3 PHit = rayOrigin + rayDir * hitT;
            float3 baryHit = projectToTriangle(PHit, v0, v1, v2);
            baryHit = clampBary(baryHit);
            float2 hitUV = baryHit.x * uv0 + baryHit.y * uv1 + baryHit.z * uv2;
            
            if (hitT >= rayTMin && hitT <= rayTMax)
            {
                uint packedUV = packUV(hitUV);
                ReportHit(hitT, 0, float2(asfloat(packedUV), 0.0));
                return;
            }
        }
        
        prevDist = dist;
    }
    
    // No intersection found
}
