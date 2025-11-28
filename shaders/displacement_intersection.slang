/*
 * RMIP - Paper's Texel Marching Implementation
 * 
 * Section 4.4 of the paper: "Texel marching"
 * 
 * The sign of ¦×(u,v) at each texel corner indicates from which edge
 * the ray leaves the texel. We march through texels by following
 * the ¦× = 0 curve.
 * 
 * ¦×(u,v) = det(P(u,v) - O, N(u,v), D) = (P(u,v) - O) ¡¤ (N(u,v) ¡Á D)
 */

#include "shaderio.h"
#include "nvshaders/gltf_scene_io.h.slang"
#include "nvshaders/gltf_vertex_access.h.slang"
#include "nvshaders/constants.h.slang"
#include "rmip_common.h.slang"

static const float DISPLACEMENT_SCALE = 0.5;
static const int MAX_MARCH_STEPS = 256;

[[vk::binding(9, 1)]] Texture2D<float> displacementMaps[8];
[[vk::binding(11, 1)]] SamplerState displacementSampler;
[[vk::push_constant]] ConstantBuffer<PathtracePushConstant> pushConst;

uint packUV(float2 uv)
{
    uint x = uint(saturate(uv.x) * 65535.0);
    uint y = uint(saturate(uv.y) * 65535.0);
    return (x << 16) | y;
}

//-----------------------------------------------------------------------------
// Triangle data with precomputed derivatives
//-----------------------------------------------------------------------------
struct Tri
{
    float3 v0, v1, v2;  // Vertices
    float3 n0, n1, n2;  // Normals
    float2 t0, t1, t2;  // TexCoords
    
    // For barycentric: P = v0 + u*du + v*dv (where u,v are in [0,1] over triangle)
    float3 du, dv;      // Position derivatives
    float3 dnu, dnv;    // Normal derivatives
    float2 dtu, dtv;    // TexCoord derivatives
};

Tri makeTri(float3 v0, float3 v1, float3 v2,
            float3 n0, float3 n1, float3 n2,
            float2 t0, float2 t1, float2 t2)
{
    Tri tri;
    tri.v0 = v0; tri.v1 = v1; tri.v2 = v2;
    tri.n0 = n0; tri.n1 = n1; tri.n2 = n2;
    tri.t0 = t0; tri.t1 = t1; tri.t2 = t2;
    
    tri.du = v1 - v0;
    tri.dv = v2 - v0;
    tri.dnu = n1 - n0;
    tri.dnv = n2 - n0;
    tri.dtu = t1 - t0;
    tri.dtv = t2 - t0;
    
    return tri;
}

// Get base position P at barycentric (u, v)
float3 P(Tri tri, float u, float v) { return tri.v0 + u * tri.du + v * tri.dv; }

// Get normal N at barycentric (u, v)
float3 N(Tri tri, float u, float v) { return tri.n0 + u * tri.dnu + v * tri.dnv; }

// Get texcoord at barycentric (u, v)
float2 T(Tri tri, float u, float v) { return tri.t0 + u * tri.dtu + v * tri.dtv; }

// Convert texcoord to barycentric
float2 texToBary(Tri tri, float2 texUV)
{
    float2 d = texUV - tri.t0;
    float det = tri.dtu.x * tri.dtv.y - tri.dtu.y * tri.dtv.x;
    if (abs(det) < 1e-10) return float2(0.33, 0.33);
    
    float u = (d.x * tri.dtv.y - d.y * tri.dtv.x) / det;
    float v = (tri.dtu.x * d.y - tri.dtu.y * d.x) / det;
    return float2(u, v);
}

//-----------------------------------------------------------------------------
// The ¦× function: ¦×(u,v) = (P(u,v) - O) ¡¤ (N(u,v) ¡Á D)
//-----------------------------------------------------------------------------
float psi(Tri tri, float u, float v, float3 O, float3 D)
{
    float3 Puv = P(tri, u, v);
    float3 Nuv = N(tri, u, v);
    return dot(Puv - O, cross(Nuv, D));
}

// Compute ¦× at a texel corner (given texel coords and corner offset)
float psiAtTexel(Tri tri, int2 texel, int2 corner, int2 texSize, float3 O, float3 D)
{
    float2 texUV = float2(texel + corner) / float2(texSize);
    float2 bary = texToBary(tri, texUV);
    return psi(tri, bary.x, bary.y, O, D);
}

//-----------------------------------------------------------------------------
// Per-texel intersection test
//-----------------------------------------------------------------------------
bool intersectTexel(Tri tri, int2 texel, int2 texSize,
                    float3 rayO, float3 rayD, uint matIdx,
                    out float hitT, out float2 hitUV)
{
    // Get texel center in UV and barycentric
    float2 texUV = (float2(texel) + 0.5) / float2(texSize);
    float2 bary = texToBary(tri, texUV);
    
    // Check if inside triangle (with tolerance for edge texels)
    float w = 1.0 - bary.x - bary.y;
    if (bary.x < -0.1 || bary.y < -0.1 || w < -0.1)
        return false;
    
    // Clamp to valid range
    bary = max(float2(0), bary);
    if (bary.x + bary.y > 1.0) bary /= (bary.x + bary.y);
    
    // Get displaced surface point
    float3 baseP = P(tri, bary.x, bary.y);
    float3 nrm = normalize(N(tri, bary.x, bary.y));
    
    float h = displacementMaps[matIdx].SampleLevel(displacementSampler, texUV, 0).r;
    h *= DISPLACEMENT_SCALE;
    
    float3 surfP = baseP + nrm * h;
    
    // Ray-plane intersection at this displaced point
    float denom = dot(rayD, nrm);
    if (abs(denom) < 1e-10) return false;
    
    float t = dot(surfP - rayO, nrm) / denom;
    if (t < 0) return false;
    
    // Check if hit point projects back to near this texel
    float3 hitP = rayO + rayD * t;
    
    // Project hit point to base plane and check if it's within texel
    float3 avgN = normalize(tri.n0 + tri.n1 + tri.n2);
    float3 centroid = (tri.v0 + tri.v1 + tri.v2) / 3.0;
    float dist = dot(hitP - centroid, avgN);
    float3 projP = hitP - avgN * dist;
    
    // Compute barycentric of projected point
    float3 e0 = tri.du;
    float3 e1 = tri.dv;
    float3 e2 = projP - tri.v0;
    
    float d00 = dot(e0, e0);
    float d01 = dot(e0, e1);
    float d11 = dot(e1, e1);
    float d20 = dot(e2, e0);
    float d21 = dot(e2, e1);
    
    float det = d00 * d11 - d01 * d01;
    if (abs(det) < 1e-10) return false;
    
    float hu = (d11 * d20 - d01 * d21) / det;
    float hv = (d00 * d21 - d01 * d20) / det;
    
    // Convert to texel coordinates
    float2 hitTexUV = T(tri, hu, hv);
    int2 hitTexel = int2(floor(hitTexUV * float2(texSize)));
    
    // Accept if within 1 texel of where we're testing
    if (abs(hitTexel.x - texel.x) > 1 || abs(hitTexel.y - texel.y) > 1)
        return false;
    
    // Additional front-face check
    if (dot(nrm, rayD) >= 0)
        return false;  // Back face
    
    hitT = t;
    hitUV = hitTexUV;
    return true;
}

//-----------------------------------------------------------------------------
// Find starting texel using ray-plane intersection
//-----------------------------------------------------------------------------
bool findStartTexel(Tri tri, float3 rayO, float3 rayD,
                    float tNear, float tFar, int2 texSize,
                    out int2 startTexel, out float2 startBary)
{
    float3 avgN = normalize(tri.n0 + tri.n1 + tri.n2);
    float3 centroid = (tri.v0 + tri.v1 + tri.v2) / 3.0;
    
    // Try to intersect base plane
    float denom = dot(rayD, avgN);
    if (abs(denom) > 1e-10)
    {
        float t = dot(centroid - rayO, avgN) / denom;
        if (t >= tNear && t <= tFar)
        {
            float3 P = rayO + rayD * t;
            float3 proj = P - avgN * dot(P - centroid, avgN);
            
            // Compute barycentric
            float3 e0 = tri.du;
            float3 e1 = tri.dv;
            float3 e2 = proj - tri.v0;
            
            float d00 = dot(e0, e0);
            float d01 = dot(e0, e1);
            float d11 = dot(e1, e1);
            float d20 = dot(e2, e0);
            float d21 = dot(e2, e1);
            
            float det = d00 * d11 - d01 * d01;
            if (abs(det) > 1e-10)
            {
                float u = (d11 * d20 - d01 * d21) / det;
                float v = (d00 * d21 - d01 * d20) / det;
                
                if (u >= -0.1 && v >= -0.1 && u + v <= 1.1)
                {
                    startBary = float2(clamp(u, 0, 1), clamp(v, 0, 1));
                    if (startBary.x + startBary.y > 1.0)
                        startBary /= (startBary.x + startBary.y);
                    
                    float2 texUV = T(tri, startBary.x, startBary.y);
                    startTexel = clamp(int2(floor(texUV * float2(texSize))), int2(0), texSize - 1);
                    return true;
                }
            }
        }
    }
    
    // Fallback: start from center
    startBary = float2(0.33, 0.33);
    float2 texUV = T(tri, 0.33, 0.33);
    startTexel = clamp(int2(floor(texUV * float2(texSize))), int2(0), texSize - 1);
    return true;
}

//-----------------------------------------------------------------------------
// Main intersection
//-----------------------------------------------------------------------------
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

    Tri tri = makeTri(v0, v1, v2, n0, n1, n2, uv0, uv1, uv2);

    // Get texture size
    uint tw, th;
    displacementMaps[matIdx].GetDimensions(tw, th);
    int2 texSize = int2(tw, th);

    // Build AABB
    float3 v0d = v0 + n0 * DISPLACEMENT_SCALE;
    float3 v1d = v1 + n1 * DISPLACEMENT_SCALE;
    float3 v2d = v2 + n2 * DISPLACEMENT_SCALE;
    
    float3 boxMin = min(min(v0, v1), v2);
    float3 boxMax = max(max(max(v0, v1), v2), max(max(v0d, v1d), v2d));
    boxMin -= 0.1; boxMax += 0.1;
    
    float3 invDir = 1.0 / rayDir;
    float3 t0 = (boxMin - rayOrigin) * invDir;
    float3 t1 = (boxMax - rayOrigin) * invDir;
    
    float tNear = max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z));
    float tFar = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
    
    if (tNear > tFar || tFar < 0) return;
    tNear = max(tNear, rayTMin);
    tFar = min(tFar, rayTMax);
    if (tNear >= tFar) return;

    // Find starting texel
    int2 texel;
    float2 bary;
    if (!findStartTexel(tri, rayOrigin, rayDir, tNear, tFar, texSize, texel, bary))
        return;

    // Texel marching
    int2 prevDir = int2(0, 0);
    
    for (int step = 0; step < MAX_MARCH_STEPS; step++)
    {
        // Bounds check
        if (texel.x < 0 || texel.x >= texSize.x || texel.y < 0 || texel.y >= texSize.y)
            break;
        
        // Test intersection in current texel
        float hitT;
        float2 hitUV;
        if (intersectTexel(tri, texel, texSize, rayOrigin, rayDir, matIdx, hitT, hitUV))
        {
            if (hitT >= rayTMin && hitT <= rayTMax)
            {
                ReportHit(hitT, 0, float2(asfloat(packUV(hitUV)), 0.0));
                return;
            }
        }
        
        // Compute ¦× at corners
        float p00 = psiAtTexel(tri, texel, int2(0,0), texSize, rayOrigin, rayDir);
        float p10 = psiAtTexel(tri, texel, int2(1,0), texSize, rayOrigin, rayDir);
        float p01 = psiAtTexel(tri, texel, int2(0,1), texSize, rayOrigin, rayDir);
        float p11 = psiAtTexel(tri, texel, int2(1,1), texSize, rayOrigin, rayDir);
        
        // Find exit edge (where ¦× changes sign, excluding entry edge)
        int2 nextDir = int2(0, 0);
        
        // Right edge: (1,0)-(1,1)
        if (p10 * p11 <= 0 && prevDir.x != 1) nextDir = int2(1, 0);
        // Left edge: (0,0)-(0,1)
        else if (p00 * p01 <= 0 && prevDir.x != -1) nextDir = int2(-1, 0);
        // Top edge: (0,1)-(1,1)
        else if (p01 * p11 <= 0 && prevDir.y != 1) nextDir = int2(0, 1);
        // Bottom edge: (0,0)-(1,0)
        else if (p00 * p10 <= 0 && prevDir.y != -1) nextDir = int2(0, -1);
        
        if (nextDir.x == 0 && nextDir.y == 0)
        {
            // No clear exit - try all edges
            if (p10 * p11 <= 0) nextDir = int2(1, 0);
            else if (p00 * p01 <= 0) nextDir = int2(-1, 0);
            else if (p01 * p11 <= 0) nextDir = int2(0, 1);
            else if (p00 * p10 <= 0) nextDir = int2(0, -1);
        }
        
        if (nextDir.x == 0 && nextDir.y == 0)
            break;  // Stuck
        
        texel += nextDir;
        prevDir = -nextDir;
    }
}
