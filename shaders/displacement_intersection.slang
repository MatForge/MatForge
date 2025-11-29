/*
 * RMIP - Paper Implementation (Thonat et al., SIGGRAPH Asia 2023)
 * "Displacement ray-tracing via inversion and oblong bounding"
 *
 * Key equations from the paper:
 * Eq 1: S(u,v) = P(u,v) + h(u,v) * N(u,v)/||N(u,v)||
 * Eq 2: (P(u,v) - Q) × N(u,v) = 0  (displacement inversion)
 * Eq 3: ψ(u,v) = det(P - O, N, D) = (P - O) · (N × D)  (implicit ray projection)
 */

#include "shaderio.h"
#include "nvshaders/gltf_scene_io.h.slang"
#include "nvshaders/gltf_vertex_access.h.slang"
#include "nvshaders/constants.h.slang"
#include "rmip_common.h.slang"

static const float DISPLACEMENT_SCALE = 0.5;
static const int MAX_NEWTON_ITERS = 8;
static const float NEWTON_EPS = 1e-6;

[[vk::binding(9, 1)]] Texture2D<float> displacementMaps[8];
[[vk::binding(11, 1)]] SamplerState displacementSampler;
[[vk::push_constant]] ConstantBuffer<PathtracePushConstant> pushConst;

uint packUV(float2 uv)
{
    uint x = uint(saturate(uv.x) * 65535.0);
    uint y = uint(saturate(uv.y) * 65535.0);
    return (x << 16) | y;
}

//=============================================================================
// Triangle data structure with precomputed derivatives
// Barycentric coords: point = v0 + u*(v1-v0) + v*(v2-v0)
//=============================================================================
struct Tri
{
    float3 v0, v1, v2;       // Vertex positions
    float3 n0, n1, n2;       // Vertex normals (displacement directions)
    float2 t0, t1, t2;       // Texture coordinates
    float3 dPdu, dPdv;       // Position derivatives
    float3 dNdu, dNdv;       // Normal derivatives
    float2 dTdu, dTdv;       // Texcoord derivatives
};

Tri makeTri(float3 v0, float3 v1, float3 v2,
            float3 n0, float3 n1, float3 n2,
            float2 t0, float2 t1, float2 t2)
{
    Tri tri;
    tri.v0 = v0; tri.v1 = v1; tri.v2 = v2;
    tri.n0 = n0; tri.n1 = n1; tri.n2 = n2;
    tri.t0 = t0; tri.t1 = t1; tri.t2 = t2;
    tri.dPdu = v1 - v0;
    tri.dPdv = v2 - v0;
    tri.dNdu = n1 - n0;
    tri.dNdv = n2 - n0;
    tri.dTdu = t1 - t0;
    tri.dTdv = t2 - t0;
    return tri;
}

// Interpolate at barycentric (u, v) where w = 1-u-v
float3 getP(Tri tri, float2 bary) { return tri.v0 + bary.x * tri.dPdu + bary.y * tri.dPdv; }
float3 getN(Tri tri, float2 bary) { return tri.n0 + bary.x * tri.dNdu + bary.y * tri.dNdv; }
float2 getT(Tri tri, float2 bary) { return tri.t0 + bary.x * tri.dTdu + bary.y * tri.dTdv; }

// Texture coord to barycentric (inverse of getT)
bool texToBary(Tri tri, float2 tex, out float2 bary)
{
    float2 d = tex - tri.t0;
    float det = tri.dTdu.x * tri.dTdv.y - tri.dTdu.y * tri.dTdv.x;
    if (abs(det) < 1e-10)
    {
        bary = float2(0.33, 0.33);
        return false;
    }
    bary = float2(
        (d.x * tri.dTdv.y - d.y * tri.dTdv.x) / det,
        (tri.dTdu.x * d.y - tri.dTdu.y * d.x) / det
    );
    return true;
}

// Check if barycentric coords are inside triangle (with tolerance)
bool baryInTriangle(float2 bary, float eps)
{
    float w = 1.0 - bary.x - bary.y;
    return bary.x >= -eps && bary.y >= -eps && w >= -eps;
}

//=============================================================================
// Ray-triangle intersection (Möller-Trumbore)
//=============================================================================
bool rayTriangleIntersect(float3 v0, float3 v1, float3 v2,
                          float3 rayO, float3 rayD,
                          out float t, out float2 bary)
{
    float3 e1 = v1 - v0;
    float3 e2 = v2 - v0;
    float3 h = cross(rayD, e2);
    float a = dot(e1, h);

    if (abs(a) < 1e-8)
    {
        t = 0;
        bary = float2(0, 0);
        return false;
    }

    float f = 1.0 / a;
    float3 s = rayO - v0;
    float u = f * dot(s, h);

    if (u < -0.001 || u > 1.001)
    {
        t = 0;
        bary = float2(0, 0);
        return false;
    }

    float3 q = cross(s, e1);
    float v = f * dot(rayD, q);

    if (v < -0.001 || u + v > 1.001)
    {
        t = 0;
        bary = float2(0, 0);
        return false;
    }

    t = f * dot(e2, q);
    bary = float2(u, v);
    return t > 0;
}

//=============================================================================
// Compute AABB that bounds the displaced triangle
//=============================================================================
void computeDisplacedAABB(Tri tri, float hMin, float hMax,
                          out float3 aabbMin, out float3 aabbMax)
{
    aabbMin = float3(1e30, 1e30, 1e30);
    aabbMax = float3(-1e30, -1e30, -1e30);

    // Check all 3 vertices at both min and max displacement
    float3 verts[3] = { tri.v0, tri.v1, tri.v2 };
    float3 norms[3] = { normalize(tri.n0), normalize(tri.n1), normalize(tri.n2) };

    for (int i = 0; i < 3; i++)
    {
        float3 pMin = verts[i] + norms[i] * hMin;
        float3 pMax = verts[i] + norms[i] * hMax;

        aabbMin = min(aabbMin, min(pMin, pMax));
        aabbMax = max(aabbMax, max(pMin, pMax));
    }

    // Add some padding
    float3 padding = (aabbMax - aabbMin) * 0.01 + float3(0.001, 0.001, 0.001);
    aabbMin -= padding;
    aabbMax += padding;
}

//=============================================================================
// Ray-AABB intersection
//=============================================================================
bool rayAABBIntersect(float3 rayO, float3 rayD, float3 aabbMin, float3 aabbMax,
                      out float tEntry, out float tExit)
{
    float3 invD = 1.0 / rayD;
    float3 t0 = (aabbMin - rayO) * invD;
    float3 t1 = (aabbMax - rayO) * invD;

    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);

    tEntry = max(max(tmin.x, tmin.y), tmin.z);
    tExit = min(min(tmax.x, tmax.y), tmax.z);

    return tEntry <= tExit && tExit > 0;
}

//=============================================================================
// Get displaced position at a texture coordinate
// Returns false if texcoord is outside triangle
//=============================================================================
bool getDisplacedPosition(Tri tri, float2 texUV, uint matIdx, out float3 pos)
{
    float2 bary;
    if (!texToBary(tri, texUV, bary))
    {
        pos = float3(0, 0, 0);
        return false;
    }

    // Check if inside triangle (with some tolerance)
    if (!baryInTriangle(bary, 0.01))
    {
        pos = float3(0, 0, 0);
        return false;
    }

    // Get base position and normal
    float3 P = getP(tri, bary);
    float3 N = normalize(getN(tri, bary));

    // Sample displacement
    float h = displacementMaps[matIdx].SampleLevel(displacementSampler, texUV, 0).r;
    h *= DISPLACEMENT_SCALE;

    // Displaced position: S = P + h * N
    pos = P + N * h;
    return true;
}

//=============================================================================
// Get displaced position at barycentric coordinates
//=============================================================================
float3 getDisplacedPositionBary(Tri tri, float2 bary, uint matIdx)
{
    // Clamp barycentric to valid range
    bary = max(float2(0), bary);
    float w = 1.0 - bary.x - bary.y;
    if (w < 0)
    {
        float s = bary.x + bary.y;
        bary /= s;
    }

    float3 P = getP(tri, bary);
    float3 N = normalize(getN(tri, bary));
    float2 texUV = getT(tri, bary);

    float h = displacementMaps[matIdx].SampleLevel(displacementSampler, texUV, 0).r;
    h *= DISPLACEMENT_SCALE;

    return P + N * h;
}

//=============================================================================
// Test ray against a single micro-triangle
//=============================================================================
bool intersectMicroTriangle(Tri tri, float2 b0, float2 b1, float2 b2,
                            uint matIdx, float3 rayO, float3 rayD, float tMin, float tMax,
                            out float hitT, out float2 hitBary)
{
    hitT = tMax + 1.0;
    hitBary = float2(0, 0);

    // Get displaced positions
    float3 p0 = getDisplacedPositionBary(tri, b0, matIdx);
    float3 p1 = getDisplacedPositionBary(tri, b1, matIdx);
    float3 p2 = getDisplacedPositionBary(tri, b2, matIdx);

    float t;
    float2 triB;
    if (rayTriangleIntersect(p0, p1, p2, rayO, rayD, t, triB))
    {
        if (t >= tMin && t <= tMax)
        {
            hitT = t;
            float w = 1.0 - triB.x - triB.y;
            hitBary = w * b0 + triB.x * b1 + triB.y * b2;
            return true;
        }
    }
    return false;
}

//=============================================================================
// Main intersection shader
//=============================================================================
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

    uint tw, th;
    displacementMaps[matIdx].GetDimensions(tw, th);
    int2 texSize = int2(tw, th);

    if (texSize.x == 0 || texSize.y == 0) return;

    //=========================================================================
    // Step 1: Compute displaced AABB and intersect ray
    //=========================================================================
    float hMin = 0.0;
    float hMax = DISPLACEMENT_SCALE;

    float3 aabbMin, aabbMax;
    computeDisplacedAABB(tri, hMin, hMax, aabbMin, aabbMax);

    float tEntry, tExit;
    if (!rayAABBIntersect(rayOrigin, rayDir, aabbMin, aabbMax, tEntry, tExit))
        return;

    tEntry = max(tEntry, rayTMin);
    tExit = min(tExit, rayTMax);
    if (tEntry >= tExit) return;

    //=========================================================================
    // Step 2: Determine tessellation resolution
    // Use triangular subdivision in barycentric space
    //=========================================================================
    // Resolution based on texture size
    int resolution = min(64, max(8, texSize.x / 8));

    float bestT = rayTMax + 1.0;
    float2 bestBary = float2(0, 0);
    bool foundHit = false;

    float step = 1.0 / float(resolution);

    // Iterate through barycentric grid using triangular tessellation
    // Each grid cell is split into 2 triangles (except at the diagonal edge)
    for (int iu = 0; iu < resolution; iu++)
    {
        float u0 = iu * step;
        float u1 = min((iu + 1) * step, 1.0);

        // Number of cells in this row decreases as u increases
        int maxIv = resolution - iu;

        for (int iv = 0; iv < maxIv; iv++)
        {
            float v0 = iv * step;
            float v1 = min((iv + 1) * step, 1.0);

            // Vertices of the grid cell
            float2 b00 = float2(u0, v0);              // Bottom-left
            float2 b10 = float2(u1, v0);              // Bottom-right
            float2 b01 = float2(u0, v1);              // Top-left
            float2 b11 = float2(u1, v1);              // Top-right

            // Clamp to triangle boundary (u + v <= 1)
            if (b10.x + b10.y > 1.0) b10 = float2(1.0 - v0, v0);
            if (b01.x + b01.y > 1.0) b01 = float2(u0, 1.0 - u0);
            if (b11.x + b11.y > 1.0) b11 = float2(1.0 - v1, v1);

            float hitT;
            float2 hitBary;

            // Triangle 1: b00, b10, b01 (always valid)
            if (intersectMicroTriangle(tri, b00, b10, b01,
                                       matIdx, rayOrigin, rayDir, rayTMin, min(rayTMax, bestT),
                                       hitT, hitBary))
            {
                if (hitT < bestT)
                {
                    bestT = hitT;
                    bestBary = hitBary;
                    foundHit = true;
                }
            }

            // Triangle 2: b10, b11, b01 (only if b11 is inside triangle)
            // Check if b11 is valid (not collapsed to the edge)
            float w11 = 1.0 - b11.x - b11.y;
            if (w11 >= -0.001 && b11.x >= -0.001 && b11.y >= -0.001)
            {
                // Make sure b11 is different from b10 and b01
                float d10 = length(b11 - b10);
                float d01 = length(b11 - b01);
                if (d10 > 0.001 && d01 > 0.001)
                {
                    if (intersectMicroTriangle(tri, b10, b11, b01,
                                               matIdx, rayOrigin, rayDir, rayTMin, min(rayTMax, bestT),
                                               hitT, hitBary))
                    {
                        if (hitT < bestT)
                        {
                            bestT = hitT;
                            bestBary = hitBary;
                            foundHit = true;
                        }
                    }
                }
            }
        }
    }

    //=========================================================================
    // Report best hit
    //=========================================================================
    if (foundHit && bestT >= rayTMin && bestT <= rayTMax)
    {
        // Convert barycentric to texture UV for the hit
        float2 hitTexUV = getT(tri, bestBary);
        ReportHit(bestT, 0, float2(asfloat(packUV(hitTexUV)), 0.0));
    }
}
