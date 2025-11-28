/*
 * RMIP Displacement Mapping - ENTRY-ONLY FIX
 * 
 * Only accepts hits where the ray crosses from ABOVE the surface to BELOW.
 * This ensures we're hitting the TOP of the displaced surface, not the bottom.
 */

#include "shaderio.h"
#include "nvshaders/gltf_scene_io.h.slang"
#include "nvshaders/gltf_vertex_access.h.slang"
#include "nvshaders/constants.h.slang"
#include "rmip_common.h.slang"

static const float DISPLACEMENT_SCALE = 0.5;
static const int NUM_MARCH_STEPS = 64;
static const int BISECTION_STEPS = 6;

[[vk::binding(8, 1)]] Texture2DArray<float2> rmipTextures[8];
[[vk::binding(9, 1)]] Texture2D<float> displacementMaps[8];
[[vk::binding(10, 1)]] SamplerState rmipSampler;
[[vk::binding(11, 1)]] SamplerState displacementSampler;
[[vk::push_constant]] ConstantBuffer<PathtracePushConstant> pushConst;

uint packUV(float2 uv)
{
    uint x = uint(saturate(uv.x) * 65535.0);
    uint y = uint(saturate(uv.y) * 65535.0);
    return (x << 16) | y;
}

float3 clampBary(float3 bary)
{
    bary = max(float3(0), bary);
    float sum = bary.x + bary.y + bary.z;
    return sum > 1e-6 ? bary / sum : float3(1.0/3.0, 1.0/3.0, 1.0/3.0);
}

bool rayAABBHit(float3 rayOrigin, float3 rayDir, float3 boxMin, float3 boxMax,
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

// Sample the displaced surface at a point and return signed distance
// Positive = point is above surface (on normal side)
// Negative = point is below surface
float sampleSurface(
    float3 P,
    float3 v0, float3 v1, float3 v2,
    float3 n0, float3 n1, float3 n2,
    float2 uv0, float2 uv1, float2 uv2,
    uint matIdx,
    out float2 outUV,
    out float3 outSurfacePos,
    out bool valid)
{
    // Project P onto base triangle plane using edge vectors
    float3 e0 = v1 - v0;
    float3 e1 = v2 - v0;
    float3 triNormal = normalize(cross(e0, e1));
    
    // Average vertex normal (this is the "up" direction for displacement)
    float3 avgNormal = normalize(n0 + n1 + n2);
    
    // If geometric and vertex normals point opposite ways, flip geometric
    if (dot(triNormal, avgNormal) < 0)
        triNormal = -triNormal;
    
    // Project P to base plane
    float3 centroid = (v0 + v1 + v2) / 3.0;
    float heightAbovePlane = dot(P - centroid, triNormal);
    float3 projP = P - triNormal * heightAbovePlane;
    
    // Compute barycentric coordinates
    float3 e2 = projP - v0;
    float d00 = dot(e0, e0);
    float d01 = dot(e0, e1);
    float d11 = dot(e1, e1);
    float d20 = dot(e2, e0);
    float d21 = dot(e2, e1);
    
    float denom = d00 * d11 - d01 * d01;
    if (abs(denom) < 1e-10)
    {
        valid = false;
        outUV = float2(0);
        outSurfacePos = float3(0);
        return 0;
    }
    
    float bv = (d11 * d20 - d01 * d21) / denom;
    float bw = (d00 * d21 - d01 * d20) / denom;
    float bu = 1.0 - bv - bw;
    float3 bary = float3(bu, bv, bw);
    
    // Check bounds
    if (bary.x < -0.2 || bary.y < -0.2 || bary.z < -0.2)
    {
        valid = false;
        outUV = float2(0);
        outSurfacePos = float3(0);
        return 0;
    }
    
    bary = clampBary(bary);
    
    // Interpolate UV
    outUV = bary.x * uv0 + bary.y * uv1 + bary.z * uv2;
    outUV = saturate(outUV);
    
    // Sample displacement
    float disp = displacementMaps[matIdx].SampleLevel(displacementSampler, outUV, 0).r;
    disp *= DISPLACEMENT_SCALE;
    
    // Compute displaced surface position
    float3 basePos = bary.x * v0 + bary.y * v1 + bary.z * v2;
    float3 normal = normalize(bary.x * n0 + bary.y * n1 + bary.z * n2);
    outSurfacePos = basePos + normal * disp;
    
    // Signed distance: positive = P is above surface
    float signedDist = dot(P - outSurfacePos, normal);
    
    valid = true;
    return signedDist;
}

[shader("intersection")]
void intersectionMain()
{
    float3 rayOrigin = ObjectRayOrigin();
    float3 rayDir = normalize(ObjectRayDirection());
    float rayTMin = RayTMin();
    float rayTMax = RayTCurrent();

    uint triangleIndex = PrimitiveIndex();
    uint instanceID = InstanceIndex();
    uint renderPrimID = InstanceID();

    GltfRenderNode* renderNodes = pushConst.gltfScene->renderNodes;
    GltfRenderPrimitive* renderPrimitives = pushConst.gltfScene->renderPrimitives;
    GltfRenderNode renderNode = renderNodes[instanceID];
    GltfRenderPrimitive renderPrim = renderPrimitives[renderPrimID];

    int materialID = max(0, renderNode.materialID);
    uint matIdx = min(uint(materialID), 7u);

    uint3 indices = getTriangleIndices(renderPrim, triangleIndex);

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

    // Build AABB
    float3 v0d = v0 + n0 * DISPLACEMENT_SCALE;
    float3 v1d = v1 + n1 * DISPLACEMENT_SCALE;
    float3 v2d = v2 + n2 * DISPLACEMENT_SCALE;
    
    float3 boxMin = min(min(v0, v1), v2);
    float3 boxMax = max(max(max(v0, v1), v2), max(max(v0d, v1d), v2d));
    
    boxMin -= (boxMax - boxMin) * 0.02;
    boxMax += (boxMax - boxMin) * 0.02;
    
    float tNear, tFar;
    if (!rayAABBHit(rayOrigin, rayDir, boxMin, boxMax, tNear, tFar))
        return;
    
    tNear = max(tNear, rayTMin);
    tFar = min(tFar, rayTMax);
    if (tNear >= tFar) return;

    // March
    float stepSize = (tFar - tNear) / float(NUM_MARCH_STEPS);
    
    float prevDist = 0;
    float prevT = tNear;
    bool prevValid = false;
    
    {
        float3 P = rayOrigin + rayDir * tNear;
        float2 uv;
        float3 surfPos;
        prevDist = sampleSurface(P, v0, v1, v2, n0, n1, n2, uv0, uv1, uv2, matIdx, uv, surfPos, prevValid);
    }
    
    for (int i = 1; i <= NUM_MARCH_STEPS; i++)
    {
        float t = tNear + stepSize * float(i);
        if (t > tFar) break;
        
        float3 P = rayOrigin + rayDir * t;
        float2 currUV;
        float3 currSurfPos;
        bool currValid;
        float currDist = sampleSurface(P, v0, v1, v2, n0, n1, n2, uv0, uv1, uv2, matIdx, currUV, currSurfPos, currValid);
        
        if (!currValid)
        {
            prevT = t;
            prevValid = false;
            continue;
        }
        
        // ENTRY HIT ONLY: must go from POSITIVE (above) to NEGATIVE (below)
        // Also accept zero crossings from positive side
        if (prevValid && prevDist > 0 && currDist <= 0)
        {
            // Bisection refinement
            float tA = prevT;
            float tB = t;
            
            for (int j = 0; j < BISECTION_STEPS; j++)
            {
                float tMid = (tA + tB) * 0.5;
                float3 PMid = rayOrigin + rayDir * tMid;
                float2 uvMid;
                float3 surfMid;
                bool validMid;
                float distMid = sampleSurface(PMid, v0, v1, v2, n0, n1, n2, uv0, uv1, uv2, matIdx, uvMid, surfMid, validMid);
                
                if (distMid > 0)
                    tA = tMid;
                else
                    tB = tMid;
            }
            
            float hitT = (tA + tB) * 0.5;
            float3 PHit = rayOrigin + rayDir * hitT;
            float2 hitUV;
            float3 hitSurfPos;
            bool hitValid;
            sampleSurface(PHit, v0, v1, v2, n0, n1, n2, uv0, uv1, uv2, matIdx, hitUV, hitSurfPos, hitValid);
            
            float finalT = dot(hitSurfPos - rayOrigin, rayDir);
            
            if (finalT >= rayTMin && finalT <= rayTMax)
            {
                ReportHit(finalT, 0, float2(asfloat(packUV(hitUV)), 0.0));
                return;
            }
        }
        
        prevDist = currDist;
        prevT = t;
        prevValid = currValid;
    }
}
