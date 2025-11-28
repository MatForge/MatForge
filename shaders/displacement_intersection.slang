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
static const int MAX_MARCH_STEPS = 256;
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
float2 texToBary(Tri tri, float2 tex)
{
    float2 d = tex - tri.t0;
    float det = tri.dTdu.x * tri.dTdv.y - tri.dTdu.y * tri.dTdv.x;
    if (abs(det) < 1e-10) return float2(0.33, 0.33);
    return float2(
        (d.x * tri.dTdv.y - d.y * tri.dTdv.x) / det,
        (tri.dTdu.x * d.y - tri.dTdu.y * d.x) / det
    );
}

// Check if barycentric coords are inside triangle (with tolerance)
bool baryInTriangle(float2 bary, float eps)
{
    float w = 1.0 - bary.x - bary.y;
    return bary.x >= -eps && bary.y >= -eps && w >= -eps;
}

//=============================================================================
// Section 4.1: Displacement Inversion (Equation 2)
// Given 3D point Q, find barycentric (u,v) such that Q lies on the
// displacement line through (u,v): solve (P(u,v) - Q) × N(u,v) = 0
//=============================================================================
bool invertDisplacement(Tri tri, float3 Q, out float2 baryOut)
{
    // Initial guess: project Q onto base triangle plane
    float3 triN = normalize(cross(tri.dPdu, tri.dPdv));
    float dist = dot(Q - tri.v0, triN);
    float3 proj = Q - dist * triN;

    // Compute barycentric of projection using Cramer's rule
    float3 v0p = proj - tri.v0;
    float d00 = dot(tri.dPdu, tri.dPdu);
    float d01 = dot(tri.dPdu, tri.dPdv);
    float d11 = dot(tri.dPdv, tri.dPdv);
    float d20 = dot(v0p, tri.dPdu);
    float d21 = dot(v0p, tri.dPdv);
    float denom = d00 * d11 - d01 * d01;

    float2 bary;
    if (abs(denom) < 1e-10)
        bary = float2(0.33, 0.33);
    else
        bary = float2((d11 * d20 - d01 * d21) / denom, (d00 * d21 - d01 * d20) / denom);

    // Newton iteration to solve (P(u,v) - Q) × N(u,v) = 0
    for (int i = 0; i < MAX_NEWTON_ITERS; i++)
    {
        float3 P = getP(tri, bary);
        float3 N = getN(tri, bary);
        float3 diff = P - Q;
        float3 F = cross(diff, N);  // Residual (should be zero)

        float residual = dot(F, F);
        if (residual < NEWTON_EPS * NEWTON_EPS) break;

        // Jacobian: dF/du = dP/du × N + diff × dN/du
        float3 dFdu = cross(tri.dPdu, N) + cross(diff, tri.dNdu);
        float3 dFdv = cross(tri.dPdv, N) + cross(diff, tri.dNdv);

        // Solve 2x2 normal equations: J^T J delta = -J^T F
        float a = dot(dFdu, dFdu);
        float b = dot(dFdu, dFdv);
        float c = dot(dFdv, dFdv);
        float rhs_u = -dot(dFdu, F);
        float rhs_v = -dot(dFdv, F);

        float det = a * c - b * b;
        if (abs(det) < 1e-12) break;

        bary.x += (c * rhs_u - b * rhs_v) / det;
        bary.y += (a * rhs_v - b * rhs_u) / det;
    }

    baryOut = bary;
    return baryInTriangle(bary, 0.1);
}

//=============================================================================
// Section 4.2: Implicit ray projection (Equation 3)
// ψ(u,v) = det(P - O, N, D) = (P - O) · (N × D)
// The curve ψ = 0 is the ray's projection in texture space
//=============================================================================
float psi(Tri tri, float2 bary, float3 O, float3 D)
{
    float3 P = getP(tri, bary);
    float3 N = getN(tri, bary);
    return dot(P - O, cross(N, D));
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

    if (u < 0.0 || u > 1.0)
    {
        t = 0;
        bary = float2(0, 0);
        return false;
    }

    float3 q = cross(s, e1);
    float v = f * dot(rayD, q);

    if (v < 0.0 || u + v > 1.0)
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
// Per-texel displaced surface intersection
// Creates a bilinear patch from the 4 texel corners and tests ray against it
//=============================================================================
bool intersectTexelMicroGeometry(Tri tri, int2 texel, int2 texSize, uint matIdx,
                                  float3 rayO, float3 rayD, float tMin, float tMax,
                                  out float hitT, out float2 hitTexUV)
{
    hitT = tMax + 1.0;
    hitTexUV = float2(0, 0);

    // Get the 4 corners of the texel in texture space
    float2 texCorners[4];
    texCorners[0] = float2(texel) / float2(texSize);           // Bottom-left
    texCorners[1] = float2(texel + int2(1, 0)) / float2(texSize); // Bottom-right
    texCorners[2] = float2(texel + int2(0, 1)) / float2(texSize); // Top-left
    texCorners[3] = float2(texel + int2(1, 1)) / float2(texSize); // Top-right

    // Convert to barycentric and get displaced positions
    float3 displaced[4];
    bool allValid = true;

    for (int i = 0; i < 4; i++)
    {
        float2 bary = texToBary(tri, texCorners[i]);

        // Check if corner is reasonably inside triangle
        if (!baryInTriangle(bary, 0.5))
        {
            allValid = false;
            break;
        }

        // Clamp barycentric to valid range
        bary = clamp(bary, float2(0), float2(1));
        if (bary.x + bary.y > 1.0)
        {
            float s = bary.x + bary.y;
            bary /= s;
        }

        // Get base position and normal
        float3 P = getP(tri, bary);
        float3 N = normalize(getN(tri, bary));

        // Sample displacement
        float h = displacementMaps[matIdx].SampleLevel(displacementSampler, texCorners[i], 0).r;
        h *= DISPLACEMENT_SCALE;

        // Displaced position: S = P + h * N
        displaced[i] = P + N * h;
    }

    if (!allValid) return false;

    // Test ray against the two triangles forming the texel quad
    // Triangle 1: corners 0, 1, 2 (bottom-left, bottom-right, top-left)
    float t1;
    float2 bary1;
    bool hit1 = rayTriangleIntersect(displaced[0], displaced[1], displaced[2],
                                     rayO, rayD, t1, bary1);

    // Triangle 2: corners 1, 3, 2 (bottom-right, top-right, top-left)
    float t2;
    float2 bary2;
    bool hit2 = rayTriangleIntersect(displaced[1], displaced[3], displaced[2],
                                     rayO, rayD, t2, bary2);

    // Find closest valid hit
    bool foundHit = false;

    if (hit1 && t1 >= tMin && t1 <= tMax && t1 < hitT)
    {
        hitT = t1;
        // Interpolate texture coords: (1-u-v)*t0 + u*t1 + v*t2
        float w = 1.0 - bary1.x - bary1.y;
        hitTexUV = w * texCorners[0] + bary1.x * texCorners[1] + bary1.y * texCorners[2];
        foundHit = true;
    }

    if (hit2 && t2 >= tMin && t2 <= tMax && t2 < hitT)
    {
        hitT = t2;
        // Interpolate texture coords for second triangle
        float w = 1.0 - bary2.x - bary2.y;
        hitTexUV = w * texCorners[1] + bary2.x * texCorners[3] + bary2.y * texCorners[2];
        foundHit = true;
    }

    return foundHit;
}

//=============================================================================
// Texel marching using psi sign changes (Section 4.4)
// The sign of psi at texel corners indicates which edge the ray exits
//=============================================================================
int2 findNextTexel(Tri tri, int2 texel, int2 texSize, float3 rayO, float3 rayD, int2 prevDir)
{
    // Compute psi at the 4 corners
    float2 c00 = float2(texel) / float2(texSize);
    float2 c10 = float2(texel + int2(1, 0)) / float2(texSize);
    float2 c01 = float2(texel + int2(0, 1)) / float2(texSize);
    float2 c11 = float2(texel + int2(1, 1)) / float2(texSize);

    float p00 = psi(tri, texToBary(tri, c00), rayO, rayD);
    float p10 = psi(tri, texToBary(tri, c10), rayO, rayD);
    float p01 = psi(tri, texToBary(tri, c01), rayO, rayD);
    float p11 = psi(tri, texToBary(tri, c11), rayO, rayD);

    // Check each edge for sign change (excluding entry edge)
    // Right edge: c10 to c11
    bool rightCross = (p10 * p11 < 0) || (p10 == 0) || (p11 == 0);
    // Left edge: c00 to c01
    bool leftCross = (p00 * p01 < 0) || (p00 == 0) || (p01 == 0);
    // Top edge: c01 to c11
    bool topCross = (p01 * p11 < 0) || (p01 == 0) || (p11 == 0);
    // Bottom edge: c00 to c10
    bool bottomCross = (p00 * p10 < 0) || (p00 == 0) || (p10 == 0);

    // Choose exit edge (not the entry edge)
    if (rightCross && prevDir.x != 1) return int2(1, 0);
    if (leftCross && prevDir.x != -1) return int2(-1, 0);
    if (topCross && prevDir.y != 1) return int2(0, 1);
    if (bottomCross && prevDir.y != -1) return int2(0, -1);

    // Fallback: try any crossing edge
    if (rightCross) return int2(1, 0);
    if (leftCross) return int2(-1, 0);
    if (topCross) return int2(0, 1);
    if (bottomCross) return int2(0, -1);

    // No exit found - check which direction has the smallest |psi| at center
    float2 center = float2(texel) / float2(texSize) + 0.5 / float2(texSize);
    float2 centerBary = texToBary(tri, center);

    // Try moving toward where psi might be zero
    float psiCenter = psi(tri, centerBary, rayO, rayD);

    // Default: move in direction where psi values suggest the ray goes
    if (abs(p10 + p11) < abs(p00 + p01)) return int2(1, 0);
    if (abs(p00 + p01) < abs(p10 + p11)) return int2(-1, 0);
    if (abs(p01 + p11) < abs(p00 + p10)) return int2(0, 1);
    return int2(0, -1);
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
    // Step 2: Project entry point to texture space using displacement inversion
    //=========================================================================
    float3 entryPoint = rayOrigin + rayDir * tEntry;
    float2 startBary;

    if (!invertDisplacement(tri, entryPoint, startBary))
    {
        // Fallback: use simple projection onto base triangle
        float t;
        float2 bary;
        if (rayTriangleIntersect(tri.v0, tri.v1, tri.v2, rayOrigin, rayDir, t, bary))
        {
            startBary = bary;
        }
        else
        {
            // Last resort: center of triangle
            startBary = float2(0.33, 0.33);
        }
    }

    // Clamp barycentric to valid range
    startBary = clamp(startBary, float2(0), float2(1));
    if (startBary.x + startBary.y > 1.0)
    {
        float s = startBary.x + startBary.y;
        startBary /= s;
    }

    // Convert to texture coordinates
    float2 startTex = getT(tri, startBary);

    // Clamp to valid texture range
    startTex = clamp(startTex, float2(0), float2(1));

    // Convert to texel index
    int2 texel = int2(floor(startTex * float2(texSize)));
    texel = clamp(texel, int2(0), texSize - int2(1));

    //=========================================================================
    // Step 3: Texel marching along the projected ray
    //=========================================================================
    float bestT = rayTMax + 1.0;
    float2 bestUV = float2(0, 0);
    bool foundHit = false;

    int2 prevDir = int2(0, 0);

    for (int step = 0; step < MAX_MARCH_STEPS; step++)
    {
        // Bounds check
        if (texel.x < 0 || texel.x >= texSize.x || texel.y < 0 || texel.y >= texSize.y)
            break;

        // Test intersection with current texel's micro-geometry
        float hitT;
        float2 hitUV;
        if (intersectTexelMicroGeometry(tri, texel, texSize, matIdx,
                                        rayOrigin, rayDir, rayTMin, min(rayTMax, bestT),
                                        hitT, hitUV))
        {
            if (hitT < bestT)
            {
                bestT = hitT;
                bestUV = hitUV;
                foundHit = true;
                // Don't break - continue to find closest hit
            }
        }

        // Find next texel using psi sign changes
        int2 nextDir = findNextTexel(tri, texel, texSize, rayOrigin, rayDir, prevDir);

        if (nextDir.x == 0 && nextDir.y == 0)
            break;  // No valid exit found

        texel += nextDir;
        prevDir = -nextDir;  // Entry edge of next texel is opposite of exit
    }

    //=========================================================================
    // Report best hit
    //=========================================================================
    if (foundHit && bestT >= rayTMin && bestT <= rayTMax)
    {
        ReportHit(bestT, 0, float2(asfloat(packUV(bestUV)), 0.0));
    }
}
