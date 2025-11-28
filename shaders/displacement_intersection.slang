/*
 * RMIP Displacement Mapping - CORRECT NORMAL VERSION
 * 
 * BUG FOUND: The geometric normal from cross(v1-v0, v2-v0) can point
 * in the OPPOSITE direction from the vertex normals!
 * 
 * For the test plane:
 * - Vertex normals: (0, 1, 0) pointing UP
 * - Geometric normal from cross: (0, -1, 0) pointing DOWN
 * 
 * This inverts all height calculations!
 * 
 * FIX: Use the average of vertex normals as the reference direction,
 * not the cross product.
 */

#include "shaderio.h"
#include "nvshaders/gltf_scene_io.h.slang"
#include "nvshaders/gltf_vertex_access.h.slang"
#include "nvshaders/constants.h.slang"
#include "rmip_common.h.slang"

// Configuration
static const float DISPLACEMENT_SCALE = 0.5;
static const int NUM_MARCH_STEPS = 64;
static const int BISECTION_STEPS = 6;

// Bindings
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

float3 projectToBasePlane(float3 P, float3 v0, float3 v1, float3 v2, float3 planeNormal, float planeD)
{
    float3 e0 = v1 - v0;
    float3 e1 = v2 - v0;
    
    float h = dot(P, planeNormal) - planeD;
    float3 projP = P - planeNormal * h;
    
    float3 e2 = projP - v0;
    float d00 = dot(e0, e0);
    float d01 = dot(e0, e1);
    float d11 = dot(e1, e1);
    float d20 = dot(e2, e0);
    float d21 = dot(e2, e1);
    
    float denom = d00 * d11 - d01 * d01;
    if (abs(denom) < 1e-10)
        return float3(-1, -1, -1);
    
    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    return float3(1.0 - v - w, v, w);
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

    // =========================================================================
    // KEY FIX: Use VERTEX NORMALS to define the "up" direction for the plane
    // The geometric normal from cross product may point the wrong way!
    // =========================================================================
    float3 avgVertexNormal = normalize(n0 + n1 + n2);
    
    // Use this as the plane normal (displacement goes in this direction)
    float3 planeNormal = avgVertexNormal;
    
    // Compute plane D using centroid
    float3 centroid = (v0 + v1 + v2) / 3.0;
    float planeD = dot(centroid, planeNormal);

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

    // =========================================================================
    // March along ray
    // diff = heightP - disp
    //   heightP = distance from P to base plane in normal direction
    //   disp = sampled displacement value
    //   diff > 0: P is above displaced surface
    //   diff < 0: P is below displaced surface
    // =========================================================================
    
    float stepSize = (tFar - tNear) / float(NUM_MARCH_STEPS);
    
    float prevDiff = 0;
    float prevT = tNear;
    bool prevValid = false;
    
    // First sample
    {
        float3 P = rayOrigin + rayDir * tNear;
        float heightP = dot(P, planeNormal) - planeD;
        
        float3 bary = projectToBasePlane(P, v0, v1, v2, planeNormal, planeD);
        if (bary.x >= -0.3 && bary.y >= -0.3 && bary.z >= -0.3)
        {
            bary = clampBary(bary);
            float2 uv = bary.x * uv0 + bary.y * uv1 + bary.z * uv2;
            uv = saturate(uv);
            float disp = displacementMaps[matIdx].SampleLevel(displacementSampler, uv, 0).r * DISPLACEMENT_SCALE;
            prevDiff = heightP - disp;
            prevValid = true;
        }
    }
    
    for (int i = 1; i <= NUM_MARCH_STEPS; i++)
    {
        float t = tNear + stepSize * float(i);
        if (t > tFar) break;
        
        float3 P = rayOrigin + rayDir * t;
        float heightP = dot(P, planeNormal) - planeD;
        
        float3 bary = projectToBasePlane(P, v0, v1, v2, planeNormal, planeD);
        
        if (bary.x < -0.3 || bary.y < -0.3 || bary.z < -0.3)
        {
            prevT = t;
            prevValid = false;
            continue;
        }
        
        bary = clampBary(bary);
        float2 uv = bary.x * uv0 + bary.y * uv1 + bary.z * uv2;
        uv = saturate(uv);
        float disp = displacementMaps[matIdx].SampleLevel(displacementSampler, uv, 0).r * DISPLACEMENT_SCALE;
        float currDiff = heightP - disp;
        
        // Check for ANY sign change (entry or exit)
        if (prevValid && prevDiff * currDiff < 0)
        {
            // Bisection refinement
            float tA = prevT;
            float tB = t;
            
            for (int j = 0; j < BISECTION_STEPS; j++)
            {
                float tMid = (tA + tB) * 0.5;
                float3 PMid = rayOrigin + rayDir * tMid;
                float heightMid = dot(PMid, planeNormal) - planeD;
                
                float3 baryMid = projectToBasePlane(PMid, v0, v1, v2, planeNormal, planeD);
                baryMid = clampBary(baryMid);
                float2 uvMid = baryMid.x * uv0 + baryMid.y * uv1 + baryMid.z * uv2;
                uvMid = saturate(uvMid);
                float dispMid = displacementMaps[matIdx].SampleLevel(displacementSampler, uvMid, 0).r * DISPLACEMENT_SCALE;
                float diffMid = heightMid - dispMid;
                
                if (diffMid * prevDiff > 0)
                    tA = tMid;
                else
                    tB = tMid;
            }
            
            // Final hit
            float hitT = (tA + tB) * 0.5;
            float3 PHit = rayOrigin + rayDir * hitT;
            
            float3 baryHit = projectToBasePlane(PHit, v0, v1, v2, planeNormal, planeD);
            baryHit = clampBary(baryHit);
            
            float2 hitUV = baryHit.x * uv0 + baryHit.y * uv1 + baryHit.z * uv2;
            hitUV = saturate(hitUV);
            
            // Compute actual surface position
            float3 basePos = baryHit.x * v0 + baryHit.y * v1 + baryHit.z * v2;
            float3 normal = normalize(baryHit.x * n0 + baryHit.y * n1 + baryHit.z * n2);
            float dispHit = displacementMaps[matIdx].SampleLevel(displacementSampler, hitUV, 0).r * DISPLACEMENT_SCALE;
            float3 surfacePos = basePos + normal * dispHit;
            
            float finalT = dot(surfacePos - rayOrigin, rayDir);
            
            if (finalT >= rayTMin && finalT <= rayTMax)
            {
                ReportHit(finalT, 0, float2(asfloat(packUV(hitUV)), 0.0));
                return;  // First hit only
            }
        }
        
        prevDiff = currDiff;
        prevT = t;
        prevValid = true;
    }
}
