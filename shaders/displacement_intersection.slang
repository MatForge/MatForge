/*
 * RMIP Displacement Mapping Custom Intersection Shader
 * Based on "RMIP: Displacement ray-tracing via inversion and oblong bounding"
 * by Thonat et al. (SIGGRAPH Asia 2023)
 */

#include "shaderio.h"
#include "nvshaders/gltf_scene_io.h.slang"
#include "nvshaders/gltf_vertex_access.h.slang"
#include "nvshaders/constants.h.slang"
#include "rmip_common.h.slang"

// RMIP Data Structure binding - matches the builder output
// The RMIP is stored as a 2D array texture with (maxLevel+1)^2 layers
// Each layer stores minmax bounds for a specific (p,q) query size
[[vk::binding(8, 1)]] Texture2DArray<float2> rmipTextures[8];     // Array of RMIP minmax bounds (one per material)
[[vk::binding(9, 1)]] Texture2D<float> displacementMaps[8];       // Array of displacement textures
[[vk::binding(10, 1)]] SamplerState rmipSampler;                  // Sampler for RMIP texture
[[vk::binding(11, 1)]] SamplerState displacementSampler;          // Sampler for displacement map

// Push constant for accessing scene data
[[vk::push_constant]] ConstantBuffer<PathtracePushConstant> pushConst;

// Constants for RMIP traversal
static const float TEXEL_MARCHING_SCALE = 2.0; // Threshold to switch to texel marching
static const int MAX_TRAVERSAL_STEPS = 64;
static const float DISPLACEMENT_SCALE = 1.0;

// Displacement parameters (could be in push constant or material)
struct DisplacementParams
{
    float scale;
    float offset;
    float2 uvScale;
    float2 uvOffset;
};

//-----------------------------------------------------------------------
// Affine Arithmetic for computing 3D bounds from 2D texture bounds
//-----------------------------------------------------------------------
struct AffineForm
{
    float3 center;
    float3 deviation;
    
    __init(float3 c, float3 d)
    {
        center = c;
        deviation = d;
    }
    
    // Get axis-aligned bounding box
    void getAABB(out float3 minBounds, out float3 maxBounds)
    {
        minBounds = center - deviation;
        maxBounds = center + deviation;
    }
};

//-----------------------------------------------------------------------
// 2D Ray bound in texture space
//-----------------------------------------------------------------------
struct RayBound2D
{
    float2 minUV;
    float2 maxUV;
    float tMin;
    float tMax;
    
    __init(float2 min, float2 max, float tmin, float tmax)
    {
        minUV = min;
        maxUV = max;
        tMin = tmin;
        tMax = tmax;
    }
    
    float2 getSize()
    {
        return maxUV - minUV;
    }
    
    float2 getCenter()
    {
        return (minUV + maxUV) * 0.5;
    }
    
    bool isSmallEnough(float threshold)
    {
        float2 size = getSize();
        return max(size.x, size.y) < threshold;
    }
};

//-----------------------------------------------------------------------
// Displacement Inversion: Project 3D point to 2D texture space
// This is a simplified version that uses barycentric interpolation
// For more accuracy, Newton iteration could be used
//-----------------------------------------------------------------------
float2 invertDisplacement(float3 worldPoint, 
                          float3 v0, float3 v1, float3 v2,  // Triangle vertices
                          float2 uv0, float2 uv1, float2 uv2, // Triangle UVs
                          float3 n0, float3 n1, float3 n2)    // Vertex normals
{
    
    // Start with barycentric coordinates of the point projected onto base triangle
    float3 bary = computeBarycentrics(worldPoint, v0, v1, v2);
    
    // Clamp to valid barycentric range
    bary = max(float3(0), min(float3(1), bary));
    float sum = bary.x + bary.y + bary.z;
    if(sum > 0.001)
        bary /= sum;
    
    // Convert barycentric to UV
    float2 uv = bary.x * uv0 + bary.y * uv1 + bary.z * uv2;
    
    return clamp(uv, 0.0, 1.0);
}

//-----------------------------------------------------------------------
// Helper: Compute barycentric coordinates
//-----------------------------------------------------------------------
float3 computeBarycentrics(float3 p, float3 v0, float3 v1, float3 v2)
{
    float3 e0 = v1 - v0;
    float3 e1 = v2 - v0;
    float3 e2 = p - v0;
    
    float d00 = dot(e0, e0);
    float d01 = dot(e0, e1);
    float d11 = dot(e1, e1);
    float d20 = dot(e2, e0);
    float d21 = dot(e2, e1);
    
    float denom = d00 * d11 - d01 * d01;
    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    float u = 1.0 - v - w;
    
    return float3(u, v, w);
}

//-----------------------------------------------------------------------
// Helper: Interpolate using barycentric coordinates from UVs
//-----------------------------------------------------------------------
float3 interpolateTriangle(float2 uv, 
                           float3 v0, float3 v1, float3 v2,
                           float2 uv0, float2 uv1, float2 uv2)
{
    // Convert UV to barycentric coordinates
    float3 bary = uvToBarycentric(uv, uv0, uv1, uv2);
    return bary.x * v0 + bary.y * v1 + bary.z * v2;
}

//-----------------------------------------------------------------------
// Helper: Convert UV to barycentric coordinates
//-----------------------------------------------------------------------
float3 uvToBarycentric(float2 uv, float2 uv0, float2 uv1, float2 uv2)
{
    float2 v0 = uv2 - uv0;
    float2 v1 = uv1 - uv0;
    float2 v2 = uv - uv0;
    
    float d00 = dot(v0, v0);
    float d01 = dot(v0, v1);
    float d11 = dot(v1, v1);
    float d20 = dot(v2, v0);
    float d21 = dot(v2, v1);
    
    float denom = d00 * d11 - d01 * d01;
    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    float u = 1.0 - v - w;
    
    return float3(u, v, w);
}

//-----------------------------------------------------------------------
// Helper: Compute Jacobian for Newton iteration
//-----------------------------------------------------------------------
float2x3 computeJacobian(float2 uv,
                         float3 v0, float3 v1, float3 v2,
                         float2 uv0, float2 uv1, float2 uv2,
                         float3 n0, float3 n1, float3 n2,
                         uint materialIndex)
{
    const float h = 0.001; // Small step for finite differences

    float2 uvPlusU = uv + float2(h, 0);
    float2 uvPlusV = uv + float2(0, h);

    float3 pos = interpolateTriangle(uv, v0, v1, v2, uv0, uv1, uv2);
    float3 posPlusU = interpolateTriangle(uvPlusU, v0, v1, v2, uv0, uv1, uv2);
    float3 posPlusV = interpolateTriangle(uvPlusV, v0, v1, v2, uv0, uv1, uv2);

    float3 normal = normalize(interpolateTriangle(uv, n0, n1, n2, uv0, uv1, uv2));
    float3 normalPlusU = normalize(interpolateTriangle(uvPlusU, n0, n1, n2, uv0, uv1, uv2));
    float3 normalPlusV = normalize(interpolateTriangle(uvPlusV, n0, n1, n2, uv0, uv1, uv2));

    float disp = displacementMaps[materialIndex].SampleLevel(rmipSampler, uv, 0).r * DISPLACEMENT_SCALE;
    float dispPlusU = displacementMaps[materialIndex].SampleLevel(rmipSampler, uvPlusU, 0).r * DISPLACEMENT_SCALE;
    float dispPlusV = displacementMaps[materialIndex].SampleLevel(rmipSampler, uvPlusV, 0).r * DISPLACEMENT_SCALE;
    
    float3 dPdU = ((posPlusU - pos) + (dispPlusU * normalPlusU - disp * normal)) / h;
    float3 dPdV = ((posPlusV - pos) + (dispPlusV * normalPlusV - disp * normal)) / h;
    
    float2x3 J;
    J[0] = dPdU;
    J[1] = dPdV;
    
    return J;
}

//-----------------------------------------------------------------------
// RMIP Query: Get displacement bounds for rectangular region
// Based on the RMIP structure: layer = p * (maxLevel + 1) + q
// where 2^p is width and 2^q is height of the query rectangle
//-----------------------------------------------------------------------
float2 queryRMIP(float2 uvMin, float2 uvMax, uint maxLevel, uint materialIndex)
{
    // Calculate query size in texels
    uint2 texSize;
    uint arraySize;
    uint numberOfLevels;
    rmipTextures[materialIndex].GetDimensions(0, texSize.x, texSize.y, arraySize, numberOfLevels);
    
    // Convert UV coordinates to texel coordinates
    float2 queryMin = uvMin * float2(texSize);
    float2 queryMax = uvMax * float2(texSize);
    float2 querySize = queryMax - queryMin;
    
    // Find the appropriate p and q values (log of width and height)
    uint p = uint(floor(log2(max(1.0, querySize.x))));
    uint q = uint(floor(log2(max(1.0, querySize.y))));
    
    // Clamp to maximum level
    p = min(p, maxLevel);
    q = min(q, maxLevel);
    
    // Calculate layer index using RMIP layout: p * (maxLevel + 1) + q
    uint layer = p * (maxLevel + 1) + q;
    
    // Query RMIP using the decomposition method from the paper
    // We need to query 4 overlapping rectangles and take their minmax
    float2 minmaxBounds = float2(1e30, -1e30);
    
    // The four query positions for overlapping rectangles
    float2 positions[4];
    positions[0] = queryMin;                                          // Top-left
    positions[1] = float2(queryMax.x - (1u << p), queryMin.y);       // Top-right
    positions[2] = float2(queryMin.x, queryMax.y - (1u << q));       // Bottom-left  
    positions[3] = queryMax - float2(1u << p, 1u << q);              // Bottom-right
    
    // Sample all four positions and combine
    for(int i = 0; i < 4; i++)
    {
        // Normalize position to UV space for sampling
        float2 uv = positions[i] / float2(texSize);
        uv = clamp(uv, 0.0, 1.0);
        
        // Sample the RMIP texture at this layer
        float2 sampledMinMax = rmipTextures[materialIndex].SampleLevel(rmipSampler, float3(uv, float(layer)), 0).xy;
        
        // Combine bounds
        minmaxBounds.x = min(minmaxBounds.x, sampledMinMax.x);
        minmaxBounds.y = max(minmaxBounds.y, sampledMinMax.y);
    }
    
    return minmaxBounds * DISPLACEMENT_SCALE;
}

//-----------------------------------------------------------------------
// Compute 3D surface bounds from 2D texture bounds using RMIP
//-----------------------------------------------------------------------
void computeSurfaceBounds(RayBound2D bound2D,
                         float3 v0, float3 v1, float3 v2,
                         float2 uv0, float2 uv1, float2 uv2,
                         float3 n0, float3 n1, float3 n2,
                         uint maxLevel,
                         uint materialIndex,
                         out float3 boxMin, out float3 boxMax)
{
    // Query displacement bounds for this rectangle using RMIP
    float2 dispBounds = queryRMIPFull(rmipTextures[materialIndex], rmipSampler,
                                      bound2D.minUV, bound2D.maxUV, maxLevel);
    
    // Sample corners and center of the UV rectangle for tighter bounds
    float2 samplePoints[5] = {
        bound2D.minUV,
        float2(bound2D.maxUV.x, bound2D.minUV.y),
        bound2D.maxUV,
        float2(bound2D.minUV.x, bound2D.maxUV.y),
        bound2D.getCenter()
    };
    
    boxMin = float3(1e30);
    boxMax = float3(-1e30);
    
    // Use affine arithmetic for tighter bounds
    for(int i = 0; i < 5; i++)
    {
        // Get barycentric coordinates for this UV point
        float3 bary = uvToBarycentric(samplePoints[i], uv0, uv1, uv2);
        
        // Interpolate position and normal
        float3 pos = bary.x * v0 + bary.y * v1 + bary.z * v2;
        float3 normal = normalize(bary.x * n0 + bary.y * n1 + bary.z * n2);
        
        // Compute displaced bounds
        float3 minDisp = pos + dispBounds.x * normal;
        float3 maxDisp = pos + dispBounds.y * normal;
        
        // Update AABB
        boxMin = min(boxMin, min(minDisp, maxDisp));
        boxMax = max(boxMax, max(minDisp, maxDisp));
    }
    
    // Add small epsilon for numerical stability
    float3 epsilon = float3(1e-6);
    boxMin -= epsilon;
    boxMax += epsilon;
}

//-----------------------------------------------------------------------
// Ray-AABB intersection
//-----------------------------------------------------------------------
bool intersectAABB(float3 rayOrigin, float3 rayDir,
                  float3 boxMin, float3 boxMax,
                  out float tMin, out float tMax)
{
    float3 invDir = 1.0 / rayDir;
    float3 t0 = (boxMin - rayOrigin) * invDir;
    float3 t1 = (boxMax - rayOrigin) * invDir;
    
    float3 tSmall = min(t0, t1);
    float3 tBig = max(t0, t1);
    
    tMin = max(max(tSmall.x, tSmall.y), tSmall.z);
    tMax = min(min(tBig.x, tBig.y), tBig.z);
    
    return tMin <= tMax && tMax >= 0;
}

//-----------------------------------------------------------------------
// Texel marching for final intersection
//-----------------------------------------------------------------------
bool texelMarch(float3 rayOrigin, float3 rayDir,
                RayBound2D bound,
                float3 v0, float3 v1, float3 v2,
                float2 uv0, float2 uv1, float2 uv2,
                float3 n0, float3 n1, float3 n2,
                uint materialIndex,
                out float hitT, out float2 hitUV)
{
    uint2 texSize;
    uint numLevels;
    displacementMaps[materialIndex].GetDimensions(0, texSize.x, texSize.y, numLevels);

    hitT = -1.0; 
    hitUV = float2(0.0, 0.0);

    float2 uvStart = bound.minUV;
    float2 uvEnd = bound.maxUV;
    float2 uvStep = 1.0 / float2(texSize);
    
    // March through texels
    int numSteps = int(length((uvEnd - uvStart) / uvStep));
    numSteps = min(numSteps, 32); // Limit marching steps
    
    for(int i = 0; i < numSteps; i++)
    {
        float t = float(i) / float(numSteps);
        float2 uv = lerp(uvStart, uvEnd, t);
        
        // Get displaced surface at this UV
        float3 pos = interpolateTriangle(uv, v0, v1, v2, uv0, uv1, uv2);
        float3 normal = normalize(interpolateTriangle(uv, n0, n1, n2, uv0, uv1, uv2));
        float disp = displacementMaps[materialIndex].SampleLevel(rmipSampler, uv, 0).r * DISPLACEMENT_SCALE;
        
        float3 displacedPos = pos + disp * normal;
        
        // Check ray-micropolygon intersection
        // Simplified: just check distance to ray
        float3 toPoint = displacedPos - rayOrigin;
        float projT = dot(toPoint, rayDir);
        float3 closestPoint = rayOrigin + projT * rayDir;
        float dist = length(displacedPos - closestPoint);
        
        if(dist < uvStep.x && projT > 0) // Hit threshold based on texel size
        {
            hitT = projT;
            hitUV = uv;
            return true;
        }
    }
    
    return false;
}

//-----------------------------------------------------------------------
// Helper: Pack UV coordinates into a uint for passing to closest hit
//-----------------------------------------------------------------------
uint packUV(float2 uv)
{
    uint x = uint(clamp(uv.x, 0.0, 1.0) * 65535.0);
    uint y = uint(clamp(uv.y, 0.0, 1.0) * 65535.0);
    return (x << 16) | y;
}

//-----------------------------------------------------------------------
// Main RMIP Traversal Algorithm
//-----------------------------------------------------------------------
[shader("intersection")]
void intersectionMain()
{
    // RMIP traversal with fallback to flat intersection for debugging

    // Get ray information
    float3 rayOrigin = ObjectRayOrigin();
    float3 rayDir = ObjectRayDirection();
    float rayTMin = RayTMin();
    float rayTMax = RayTCurrent();

    // Get primitive information
    uint triangleIndex = PrimitiveIndex();    // Which triangle in the BLAS
    uint instanceID = InstanceIndex();        // Which instance in TLAS (also node ID)
    uint renderPrimID = InstanceID();         // Custom primitive ID

    // Access GLTF scene data buffers
    GltfRenderNode* renderNodes = pushConst.gltfScene->renderNodes;
    GltfRenderPrimitive* renderPrimitives = pushConst.gltfScene->renderPrimitives;

    GltfRenderNode renderNode = renderNodes[instanceID];
    GltfRenderPrimitive renderPrim = renderPrimitives[renderPrimID];

    // Get material index to select correct RMIP/displacement texture
    int materialID = max(0, renderNode.materialID);
    uint materialIndex = min(uint(materialID), 7u);  // Clamp to array size

    // Get RMIP texture dimensions and compute maxLevel once
    uint2 rmipTexSize;
    uint rmipArraySize;
    uint rmipNumLevels;
    rmipTextures[materialIndex].GetDimensions(0, rmipTexSize.x, rmipTexSize.y, rmipArraySize, rmipNumLevels);
    uint maxLevel = uint(log2(float(rmipTexSize.x))); // Assuming square texture

    // Get triangle indices from index buffer
    uint3 indices = getTriangleIndices(renderPrim, triangleIndex);

    // Fetch vertex positions
    float3 v0 = getVertexPosition(renderPrim, indices.x);
    float3 v1 = getVertexPosition(renderPrim, indices.y);
    float3 v2 = getVertexPosition(renderPrim, indices.z);

    // Fetch vertex normals
    float3 n0, n1, n2;
    if(hasVertexNormal(renderPrim))
    {
        n0 = getVertexNormal(renderPrim, indices.x);
        n1 = getVertexNormal(renderPrim, indices.y);
        n2 = getVertexNormal(renderPrim, indices.z);
    }
    else
    {
        // Compute geometric normal if no vertex normals
        float3 geoNormal = normalize(cross(v1 - v0, v2 - v0));
        n0 = n1 = n2 = geoNormal;
    }

    // Fetch texture coordinates
    float2 uv0 = getInterpolatedVertexTexCoord0(renderPrim, indices, float3(1.0, 0.0, 0.0));
    float2 uv1 = getInterpolatedVertexTexCoord0(renderPrim, indices, float3(0.0, 1.0, 0.0));
    float2 uv2 = getInterpolatedVertexTexCoord0(renderPrim, indices, float3(0.0, 0.0, 1.0));

    // DEBUG: For now, just use simple flat intersection
    // We'll add displacement marching once this works

    // Simple ray-triangle intersection (Möller-Trumbore)
    float3 edge1 = v1 - v0;
    float3 edge2 = v2 - v0;
    float3 h = cross(rayDir, edge2);
    float a = dot(edge1, h);

    if (abs(a) < 0.00001)
        return; // Ray parallel to triangle

    float f = 1.0 / a;
    float3 s = rayOrigin - v0;
    float u = f * dot(s, h);

    if (u < 0.0 || u > 1.0)
        return;

    float3 q = cross(s, edge1);
    float v = f * dot(rayDir, q);

    if (v < 0.0 || u + v > 1.0)
        return;

    float t = f * dot(edge2, q);

    if (t < rayTMin || t > rayTMax)
        return;

    // Interpolate UV
    float w = 1.0 - u - v;
    float2 hitUV = w * uv0 + u * uv1 + v * uv2;

    // Pack UV and report hit
    uint packedUV = packUV(hitUV);
    float2 hitAttribs = float2(asfloat(packedUV), 0.0);
    ReportHit(t, 0, hitAttribs);
}  // END DEBUG: Commented out original code

//-----------------------------------------------------------------------
// Helper: Intersect ray with bounding prism
//-----------------------------------------------------------------------
bool intersectPrism(float3 rayOrigin, float3 rayDir,
                   float3 v0, float3 v1, float3 v2,
                   float3 n0, float3 n1, float3 n2,
                   uint maxLevel,
                   uint materialIndex,
                   out float tMin, out float tMax)
{
    // Get displacement bounds from RMIP (query entire texture)
    float2 globalDispBounds = queryRMIP(float2(0, 0), float2(1, 1), maxLevel, materialIndex);
    float minDisp = globalDispBounds.x;
    float maxDisp = globalDispBounds.y;

    // Compute displaced vertex positions (both min and max displacement)
    float3 v0_min = v0 + n0 * minDisp;
    float3 v0_max = v0 + n0 * maxDisp;
    float3 v1_min = v1 + n1 * minDisp;
    float3 v1_max = v1 + n1 * maxDisp;
    float3 v2_min = v2 + n2 * minDisp;
    float3 v2_max = v2 + n2 * maxDisp;

    // Compute AABB that contains all displaced vertices
    float3 prismMin = min(min(min(min(min(v0_min, v0_max), v1_min), v1_max), v2_min), v2_max);
    float3 prismMax = max(max(max(max(max(v0_max, v0_min), v1_max), v1_min), v2_max), v2_min);

    // Intersect ray with prism AABB
    return intersectAABB(rayOrigin, rayDir, prismMin, prismMax, tMin, tMax);
}
