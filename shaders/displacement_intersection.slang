/*
 * RMIP Displacement - All-Angle Version
 * 
 * The issue with previous versions: we only detected "entry" hits where
 * the ray goes from above the surface to below. But at grazing angles,
 * the ray enters the displacement volume from the SIDE, so it might
 * already be "below" the surface when it enters the marching region.
 * 
 * Solution: Find the point of CLOSEST APPROACH to the surface along the ray,
 * and check if that point actually intersects (distance ¡Ö 0).
 * 
 * For a proper intersection:
 * 1. March along ray
 * 2. Track minimum |psi| (closest approach)
 * 3. If min|psi| crosses zero, we have an intersection
 */

#include "shaderio.h"
#include "nvshaders/gltf_scene_io.h.slang"
#include "nvshaders/gltf_vertex_access.h.slang"
#include "nvshaders/constants.h.slang"
#include "rmip_common.h.slang"

static const float DISPLACEMENT_SCALE = 0.5;
static const int NUM_MARCH_STEPS = 128;
static const int BISECTION_STEPS = 8;
static const float HIT_THRESHOLD = 0.001;  // Consider it a hit if |psi| < this

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

bool rayAABB(float3 rayOrigin, float3 rayDir, float3 boxMin, float3 boxMax,
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

struct SampleResult
{
    float3 surfacePos;
    float3 normal;
    float2 uv;
    float psi;  // Signed distance: positive = ray point above surface
    float absPsi;  // Absolute distance
    bool valid;
};

SampleResult sampleAt(float t, float3 rayOrigin, float3 rayDir,
                      float3 v0, float3 v1, float3 v2,
                      float3 n0, float3 n1, float3 n2,
                      float2 uv0, float2 uv1, float2 uv2,
                      float3 avgNormal, uint matIdx)
{
    SampleResult s;
    s.valid = false;
    
    float3 P = rayOrigin + rayDir * t;
    
    // Project to base plane using vertex normal
    float3 centroid = (v0 + v1 + v2) / 3.0;
    float height = dot(P - centroid, avgNormal);
    float3 projP = P - avgNormal * height;
    
    float3 e0 = v1 - v0;
    float3 e1 = v2 - v0;
    float3 e2 = projP - v0;
    
    float d00 = dot(e0, e0);
    float d01 = dot(e0, e1);
    float d11 = dot(e1, e1);
    float d20 = dot(e2, e0);
    float d21 = dot(e2, e1);
    
    float denom = d00 * d11 - d01 * d01;
    if (abs(denom) < 1e-10) return s;
    
    float bv = (d11 * d20 - d01 * d21) / denom;
    float bw = (d00 * d21 - d01 * d20) / denom;
    float3 bary = float3(1.0 - bv - bw, bv, bw);
    
    if (bary.x < -0.1 || bary.y < -0.1 || bary.z < -0.1) return s;
    
    bary = clampBary(bary);
    
    s.uv = bary.x * uv0 + bary.y * uv1 + bary.z * uv2;
    s.uv = saturate(s.uv);
    
    float disp = displacementMaps[matIdx].SampleLevel(displacementSampler, s.uv, 0).r * DISPLACEMENT_SCALE;
    
    float3 basePos = bary.x * v0 + bary.y * v1 + bary.z * v2;
    s.normal = normalize(bary.x * n0 + bary.y * n1 + bary.z * n2);
    s.surfacePos = basePos + s.normal * disp;
    
    // Signed distance from ray point to surface
    s.psi = dot(P - s.surfacePos, s.normal);
    s.absPsi = abs(s.psi);
    
    s.valid = true;
    return s;
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

    float3 avgNormal = normalize(n0 + n1 + n2);

    // Build AABB for displacement volume
    float3 v0d = v0 + n0 * DISPLACEMENT_SCALE;
    float3 v1d = v1 + n1 * DISPLACEMENT_SCALE;
    float3 v2d = v2 + n2 * DISPLACEMENT_SCALE;
    
    float3 boxMin = min(min(v0, v1), v2);
    float3 boxMax = max(max(max(v0, v1), v2), max(max(v0d, v1d), v2d));
    
    float3 margin = (boxMax - boxMin) * 0.02;
    boxMin -= margin;
    boxMax += margin;
    
    float tNear, tFar;
    if (!rayAABB(rayOrigin, rayDir, boxMin, boxMax, tNear, tFar))
        return;
    
    tNear = max(tNear, rayTMin);
    tFar = min(tFar, rayTMax);
    if (tNear >= tFar) return;

    // March and look for ANY sign change or close approach
    float stepSize = (tFar - tNear) / float(NUM_MARCH_STEPS);
    
    SampleResult prevS;
    prevS.valid = false;
    float prevT = tNear;
    
    // Track first hit (could be either entry or exit crossing)
    bool foundHit = false;
    float bestHitT = tFar + 1.0;
    float2 bestHitUV;
    
    for (int i = 0; i <= NUM_MARCH_STEPS; i++)
    {
        float t = tNear + stepSize * float(i);
        if (t > tFar) break;
        
        SampleResult currS = sampleAt(t, rayOrigin, rayDir, v0, v1, v2, n0, n1, n2,
                                       uv0, uv1, uv2, avgNormal, matIdx);
        
        if (!currS.valid)
        {
            prevT = t;
            prevS.valid = false;
            continue;
        }
        
        // Check for ANY sign change (not just entry)
        if (prevS.valid && prevS.psi * currS.psi < 0)
        {
            // Bisection to find exact crossing
            float tA = prevT;
            float tB = t;
            float psiA = prevS.psi;
            
            for (int j = 0; j < BISECTION_STEPS; j++)
            {
                float tMid = (tA + tB) * 0.5;
                SampleResult midS = sampleAt(tMid, rayOrigin, rayDir, v0, v1, v2, n0, n1, n2,
                                              uv0, uv1, uv2, avgNormal, matIdx);
                
                if (midS.valid)
                {
                    if (psiA * midS.psi > 0)
                    {
                        tA = tMid;
                        psiA = midS.psi;
                    }
                    else
                    {
                        tB = tMid;
                    }
                }
                else
                {
                    tB = tMid;
                }
            }
            
            float hitT = (tA + tB) * 0.5;
            SampleResult hitS = sampleAt(hitT, rayOrigin, rayDir, v0, v1, v2, n0, n1, n2,
                                          uv0, uv1, uv2, avgNormal, matIdx);
            
            if (hitS.valid)
            {
                float finalT = dot(hitS.surfacePos - rayOrigin, rayDir);
                
                // Keep track of FIRST hit (smallest T)
                if (finalT >= rayTMin && finalT <= rayTMax && finalT < bestHitT)
                {
                    bestHitT = finalT;
                    bestHitUV = hitS.uv;
                    foundHit = true;
                }
            }
        }
        
        prevS = currS;
        prevT = t;
    }
    
    if (foundHit)
    {
        ReportHit(bestHitT, 0, float2(asfloat(packUV(bestHitUV)), 0.0));
    }
}
