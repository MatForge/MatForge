/*
 * RMIP - Paper Implementation (Thonat et al., SIGGRAPH Asia 2023)
 * "Displacement ray-tracing via inversion and oblong bounding"
 *
 * Key equations from the paper:
 * Eq 1: S(u,v) = P(u,v) + h(u,v) * N(u,v)/||N(u,v)||
 * Eq 2: (P(u,v) - Q) × N(u,v) = 0  (displacement inversion)
 * Eq 3: ψ(u,v) = det(P - O, N, D) = (P - O) · (N × D)  (implicit ray projection)
 *
 * Algorithm: Ping-pong between 2D texture space and 3D object space
 */

#include "shaderio.h"
#include "nvshaders/gltf_scene_io.h.slang"
#include "nvshaders/gltf_vertex_access.h.slang"
#include "nvshaders/constants.h.slang"
#include "rmip_common.h.slang"

static const float DISPLACEMENT_SCALE = 0.5;
static const int MAX_NEWTON_ITERS = 8;
static const float NEWTON_EPS = 1e-6;
static const int MAX_TRAVERSAL_ITERS = 128;
static const int MAX_TEXEL_MARCH_STEPS = 128;
static const float MARCHING_SCALE = 4.0;  // Switch to texel marching when bound < MARCHING_SCALE texels

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
// Custom hit attributes for displacement - includes geometric normal
//=============================================================================
struct DisplacementHitAttributes
{
    float2 data;  // x = packed UV, y = packed normal
};

// Octahedron encoding for normals (pack float3 into float)
float2 octEncode(float3 n)
{
    n /= (abs(n.x) + abs(n.y) + abs(n.z));
    if (n.z < 0)
    {
        float2 wrapped = (1.0 - abs(n.yx)) * float2(n.x >= 0 ? 1.0 : -1.0, n.y >= 0 ? 1.0 : -1.0);
        n.xy = wrapped;
    }
    return n.xy * 0.5 + 0.5;
}

uint packNormal(float3 n)
{
    float2 oct = octEncode(normalize(n));
    uint x = uint(saturate(oct.x) * 65535.0);
    uint y = uint(saturate(oct.y) * 65535.0);
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

// Barycentric to texture coord
float2 baryToTex(Tri tri, float2 bary)
{
    return tri.t0 + bary.x * tri.dTdu + bary.y * tri.dTdv;
}

// Check if barycentric coords are inside triangle (with tolerance)
bool baryInTriangle(float2 bary, float eps)
{
    float w = 1.0 - bary.x - bary.y;
    return bary.x >= -eps && bary.y >= -eps && w >= -eps;
}

// Clamp barycentric coords to triangle
float2 clampBary(float2 bary)
{
    bary = max(float2(0), bary);
    float w = 1.0 - bary.x - bary.y;
    if (w < 0)
    {
        float s = bary.x + bary.y;
        bary /= s;
    }
    return bary;
}

//=============================================================================
// Eq. 2: Inverse Displacement Mapping via Newton iteration
// Find (u,v) such that the displacement line at (u,v) passes through point Q
// Solves: (P(u,v) - Q) × N(u,v) = 0
//=============================================================================
bool inverseDisplacement(Tri tri, float3 Q, out float2 bary)
{
    // Initial guess: project Q onto base triangle plane
    float3 normal = normalize(cross(tri.dPdu, tri.dPdv));
    float d = dot(normal, tri.v0);
    float t = (d - dot(normal, Q)) / max(dot(normal, normal), 1e-10);
    float3 projQ = Q + t * normal;

    // Solve for barycentric of projected point
    float3 v0Q = projQ - tri.v0;
    float d00 = dot(tri.dPdu, tri.dPdu);
    float d01 = dot(tri.dPdu, tri.dPdv);
    float d11 = dot(tri.dPdv, tri.dPdv);
    float d20 = dot(v0Q, tri.dPdu);
    float d21 = dot(v0Q, tri.dPdv);
    float denom = d00 * d11 - d01 * d01;
    if (abs(denom) < 1e-10)
    {
        bary = float2(0.33, 0.33);
        return false;
    }
    bary = float2(
        (d11 * d20 - d01 * d21) / denom,
        (d00 * d21 - d01 * d20) / denom
    );

    // Newton iteration to refine
    // F(u,v) = (P(u,v) - Q) × N(u,v) = 0
    for (int iter = 0; iter < MAX_NEWTON_ITERS; iter++)
    {
        float3 P = getP(tri, bary);
        float3 N = getN(tri, bary);
        float3 PmQ = P - Q;

        // F = PmQ × N (we use the x and y components)
        float3 F = cross(PmQ, N);

        // Check convergence
        if (length(F) < NEWTON_EPS)
            break;

        // Jacobian: dF/d(u,v)
        // dF/du = dPdu × N + PmQ × dNdu
        // dF/dv = dPdv × N + PmQ × dNdv
        float3 dFdu = cross(tri.dPdu, N) + cross(PmQ, tri.dNdu);
        float3 dFdv = cross(tri.dPdv, N) + cross(PmQ, tri.dNdv);

        // Solve 2x2 system using x,y components of F
        // [dFdu.x  dFdv.x] [du]   [-F.x]
        // [dFdu.y  dFdv.y] [dv] = [-F.y]
        float det = dFdu.x * dFdv.y - dFdu.y * dFdv.x;
        if (abs(det) < 1e-10)
        {
            // Try z component
            det = dFdu.x * dFdv.z - dFdu.z * dFdv.x;
            if (abs(det) < 1e-10)
            {
                det = dFdu.y * dFdv.z - dFdu.z * dFdv.y;
                if (abs(det) < 1e-10)
                    break;
                float du = (-F.y * dFdv.z + F.z * dFdv.y) / det;
                float dv = (-dFdu.y * F.z + dFdu.z * F.y) / det;
                bary -= float2(du, dv);
            }
            else
            {
                float du = (-F.x * dFdv.z + F.z * dFdv.x) / det;
                float dv = (-dFdu.x * F.z + dFdu.z * F.x) / det;
                bary -= float2(du, dv);
            }
        }
        else
        {
            float du = (-F.x * dFdv.y + F.y * dFdv.x) / det;
            float dv = (-dFdu.x * F.y + dFdu.y * F.x) / det;
            bary -= float2(du, dv);
        }
    }

    return baryInTriangle(bary, 0.1);
}

//=============================================================================
// Eq. 3: Implicit ray projection (psi function)
// ψ(u,v) = det(P - O, N, D) = (P - O) · (N × D)
// Points on the ray project to the curve ψ = 0 in texture space
//=============================================================================
float psi(Tri tri, float2 bary, float3 rayO, float3 rayD)
{
    float3 P = getP(tri, bary);
    float3 N = getN(tri, bary);
    float3 NxD = cross(N, rayD);
    return dot(P - rayO, NxD);
}

// Partial derivatives of psi (Eq. 4)
// ψu = (Pu - O)·(N×D) + (P-O)·(Nu×D) = Pu·(N×D) + (P-O)·(Nu×D)
// ψv = (Pv - O)·(N×D) + (P-O)·(Nv×D) = Pv·(N×D) + (P-O)·(Nv×D)
float2 psiGrad(Tri tri, float2 bary, float3 rayO, float3 rayD)
{
    float3 P = getP(tri, bary);
    float3 N = getN(tri, bary);
    float3 NxD = cross(N, rayD);
    float3 PmO = P - rayO;

    float3 NuxD = cross(tri.dNdu, rayD);
    float3 NvxD = cross(tri.dNdv, rayD);

    float psi_u = dot(tri.dPdu, NxD) + dot(PmO, NuxD);
    float psi_v = dot(tri.dPdv, NxD) + dot(PmO, NvxD);

    return float2(psi_u, psi_v);
}

//=============================================================================
// Find ray parameter t for a point at barycentric coords with displacement h
// Uses: Q = O + t*D, and Q lies on displacement line through (u,v)
//=============================================================================
float getRayT(Tri tri, float2 bary, float h, float3 rayO, float3 rayD)
{
    float3 P = getP(tri, bary);
    float3 N = normalize(getN(tri, bary));
    float3 S = P + h * N;  // Displaced point

    // Find t such that O + t*D is closest to S
    float3 OtoS = S - rayO;
    return dot(OtoS, rayD) / max(dot(rayD, rayD), 1e-10);
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
// Check if a rectangular barycentric region overlaps the valid triangle domain
// Triangle domain: u >= 0, v >= 0, u + v <= 1
//=============================================================================
bool regionOverlapsTriangle(float2 baryMin, float2 baryMax)
{
    // If the minimum u+v corner (baryMin) is already outside, entire region is outside
    if (baryMin.x + baryMin.y > 1.0 + 0.001)
        return false;
    // If the region is entirely in negative u or v space
    if (baryMax.x < -0.001 || baryMax.y < -0.001)
        return false;
    return true;
}

//=============================================================================
// Compute AABB for displaced surface over a barycentric region
// Properly handles partial overlap with the triangle domain (u + v <= 1)
//=============================================================================
void computeRegionAABB(Tri tri, float2 baryMin, float2 baryMax,
                       float hMin, float hMax,
                       out float3 aabbMin, out float3 aabbMax)
{
    aabbMin = float3(1e30, 1e30, 1e30);
    aabbMax = float3(-1e30, -1e30, -1e30);

    // Helper to add a sample point to the AABB
    // Only adds if point is inside or near the triangle
    #define ADD_SAMPLE(bary) { \
        float2 b = bary; \
        if (b.x >= -0.01 && b.y >= -0.01 && b.x + b.y <= 1.01) { \
            b = clampBary(b); \
            float3 P = getP(tri, b); \
            float3 N = normalize(getN(tri, b)); \
            float3 pMin = P + N * hMin; \
            float3 pMax = P + N * hMax; \
            aabbMin = min(aabbMin, min(pMin, pMax)); \
            aabbMax = max(aabbMax, max(pMin, pMax)); \
        } \
    }

    // Sample the four corners of the rectangular region
    ADD_SAMPLE(baryMin);
    ADD_SAMPLE(float2(baryMax.x, baryMin.y));
    ADD_SAMPLE(float2(baryMin.x, baryMax.y));
    ADD_SAMPLE(baryMax);

    // Also sample center
    float2 center = (baryMin + baryMax) * 0.5;
    ADD_SAMPLE(center);

    // Sample points along the triangle's hypotenuse (u + v = 1) if the region overlaps it
    // The hypotenuse intersects the rectangle if:
    // - The min corner has u+v < 1 AND max corner has u+v > 1
    if (baryMin.x + baryMin.y < 1.0 && baryMax.x + baryMax.y > 1.0)
    {
        // Find intersections of u+v=1 with the rectangle edges
        // Intersection with left edge (u = baryMin.x): v = 1 - baryMin.x
        float v_left = 1.0 - baryMin.x;
        if (v_left >= baryMin.y && v_left <= baryMax.y)
            ADD_SAMPLE(float2(baryMin.x, v_left));

        // Intersection with right edge (u = baryMax.x): v = 1 - baryMax.x
        float v_right = 1.0 - baryMax.x;
        if (v_right >= baryMin.y && v_right <= baryMax.y)
            ADD_SAMPLE(float2(baryMax.x, v_right));

        // Intersection with bottom edge (v = baryMin.y): u = 1 - baryMin.y
        float u_bottom = 1.0 - baryMin.y;
        if (u_bottom >= baryMin.x && u_bottom <= baryMax.x)
            ADD_SAMPLE(float2(u_bottom, baryMin.y));

        // Intersection with top edge (v = baryMax.y): u = 1 - baryMax.y
        float u_top = 1.0 - baryMax.y;
        if (u_top >= baryMin.x && u_top <= baryMax.x)
            ADD_SAMPLE(float2(u_top, baryMax.y));
    }

    #undef ADD_SAMPLE

    // If no valid samples were found, create a small default box
    if (aabbMin.x > aabbMax.x)
    {
        // Degenerate region - use clamped center
        float2 b = clampBary(center);
        float3 P = getP(tri, b);
        float3 N = normalize(getN(tri, b));
        aabbMin = P + N * hMin - float3(0.01, 0.01, 0.01);
        aabbMax = P + N * hMax + float3(0.01, 0.01, 0.01);
    }

    // Add padding for interpolation
    float3 padding = (aabbMax - aabbMin) * 0.05 + float3(0.001, 0.001, 0.001);
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
// Sample displacement at texture coordinates
//=============================================================================
float sampleDisplacement(uint matIdx, float2 texUV)
{
    return displacementMaps[matIdx].SampleLevel(displacementSampler, texUV, 0).r * DISPLACEMENT_SCALE;
}

//=============================================================================
// Get min/max displacement over a texture region (simple sampling)
// In a full implementation, this would query the RMIP structure
//=============================================================================
void getDisplacementBounds(uint matIdx, float2 texMin, float2 texMax, int2 texSize,
                           out float hMin, out float hMax)
{
    hMin = 0.0;
    hMax = DISPLACEMENT_SCALE;

    // For tighter bounds, sample the region
    int samples = 4;
    float minH = 1e30;
    float maxH = -1e30;

    for (int i = 0; i <= samples; i++)
    {
        for (int j = 0; j <= samples; j++)
        {
            float2 uv = lerp(texMin, texMax, float2(i, j) / float(samples));
            float h = sampleDisplacement(matIdx, uv);
            minH = min(minH, h);
            maxH = max(maxH, h);
        }
    }

    hMin = minH - 0.01 * DISPLACEMENT_SCALE;
    hMax = maxH + 0.01 * DISPLACEMENT_SCALE;
}

//=============================================================================
// Intersect displaced micro-triangle at given barycentric corners
//=============================================================================
bool intersectMicroTriangle(Tri tri, float2 b0, float2 b1, float2 b2,
                            uint matIdx, float3 rayO, float3 rayD,
                            float tMin, float tMax,
                            out float hitT, out float2 hitBary, out float3 hitGeoNormal)
{
    hitT = tMax + 1.0;
    hitBary = float2(0, 0);
    hitGeoNormal = float3(0, 1, 0);

    // Get texture coordinates and sample displacement
    float2 tex0 = baryToTex(tri, b0);
    float2 tex1 = baryToTex(tri, b1);
    float2 tex2 = baryToTex(tri, b2);

    float h0 = sampleDisplacement(matIdx, tex0);
    float h1 = sampleDisplacement(matIdx, tex1);
    float h2 = sampleDisplacement(matIdx, tex2);

    // Get displaced positions
    float3 P0 = getP(tri, b0);
    float3 P1 = getP(tri, b1);
    float3 P2 = getP(tri, b2);

    float3 N0 = normalize(getN(tri, b0));
    float3 N1 = normalize(getN(tri, b1));
    float3 N2 = normalize(getN(tri, b2));

    float3 p0 = P0 + N0 * h0;
    float3 p1 = P1 + N1 * h1;
    float3 p2 = P2 + N2 * h2;

    float t;
    float2 triB;
    if (rayTriangleIntersect(p0, p1, p2, rayO, rayD, t, triB))
    {
        if (t >= tMin && t <= tMax)
        {
            hitT = t;
            float w = 1.0 - triB.x - triB.y;
            hitBary = w * b0 + triB.x * b1 + triB.y * b2;

            // Compute geometric normal from the micro-triangle
            float3 e1 = p1 - p0;
            float3 e2 = p2 - p0;
            hitGeoNormal = normalize(cross(e1, e2));

            // Ensure normal faces the ray
            if (dot(hitGeoNormal, rayD) > 0)
                hitGeoNormal = -hitGeoNormal;

            return true;
        }
    }
    return false;
}

//=============================================================================
// 2D Ray Bound structure for the hierarchical traversal
//=============================================================================
struct RayBound2D
{
    float2 baryMin;  // Min barycentric coords
    float2 baryMax;  // Max barycentric coords
    float tMin;      // Min ray parameter
    float tMax;      // Max ray parameter
};

//=============================================================================
// Tessellate and test a small barycentric region using TRIANGULAR tessellation
// This properly covers the triangular barycentric domain (u + v <= 1)
//=============================================================================
bool tessellateRegion(Tri tri, uint matIdx, float3 rayO, float3 rayD,
                      float2 baryMin, float2 baryMax, float rayTMin, float rayTMax,
                      int2 texSize,
                      out float hitT, out float2 hitBary, out float3 hitGeoNormal)
{
    hitT = rayTMax + 1.0;
    hitBary = float2(0, 0);
    hitGeoNormal = float3(0, 1, 0);

    // Determine tessellation resolution based on region size in texture space
    float2 texMin = baryToTex(tri, baryMin);
    float2 texMax = baryToTex(tri, baryMax);
    float2 texSize2 = abs(texMax - texMin) * float2(texSize);

    int res = int(max(texSize2.x, texSize2.y)) + 1;
    res = clamp(res, 2, 8);  // 2x2 to 8x8 tessellation

    float bestT = rayTMax + 1.0;
    bool found = false;

    float2 barySize = baryMax - baryMin;
    float stepU = barySize.x / float(res);
    float stepV = barySize.y / float(res);

    // Use simple rectangular tessellation for ALL regions
    // Individual cells outside the triangle are handled by the skip check below
    for (int iu = 0; iu < res; iu++)
    {
        for (int iv = 0; iv < res; iv++)
        {
            // Four corners of this cell (some may be outside valid domain)
            float2 b00 = baryMin + float2(iu * stepU, iv * stepV);
            float2 b10 = baryMin + float2((iu + 1) * stepU, iv * stepV);
            float2 b01 = baryMin + float2(iu * stepU, (iv + 1) * stepV);
            float2 b11 = baryMin + float2((iu + 1) * stepU, (iv + 1) * stepV);

            // Skip cells that are entirely outside the base triangle
            if (b00.x + b00.y > 1.01)
                continue;

            // Clamp vertices to the triangle boundary (u + v <= 1)
            if (b10.x + b10.y > 1.0) b10 = float2(1.0 - b10.y, b10.y);
            if (b01.x + b01.y > 1.0) b01 = float2(b01.x, 1.0 - b01.x);
            if (b11.x + b11.y > 1.0) b11 = float2(0.5 * (1.0 - b11.y + b11.x), 0.5 * (1.0 - b11.x + b11.y));

            // Ensure all coords are non-negative
            b00 = max(b00, float2(0, 0));
            b10 = max(b10, float2(0, 0));
            b01 = max(b01, float2(0, 0));
            b11 = max(b11, float2(0, 0));

            float microT;
            float2 microBary;
            float3 microNormal;

            // Triangle 1: b00, b10, b01 (always test this one)
            float area1 = abs((b10.x - b00.x) * (b01.y - b00.y) - (b01.x - b00.x) * (b10.y - b00.y));
            if (area1 > 1e-6)
            {
                if (intersectMicroTriangle(tri, b00, b10, b01, matIdx, rayO, rayD,
                                           rayTMin, min(rayTMax, bestT),
                                           microT, microBary, microNormal))
                {
                    if (microT < bestT)
                    {
                        bestT = microT;
                        hitT = microT;
                        hitBary = microBary;
                        hitGeoNormal = microNormal;
                        found = true;
                    }
                }
            }

            // Triangle 2: b10, b11, b01 (only if b11 is valid - not on the diagonal edge)
            float w11 = 1.0 - b11.x - b11.y;
            if (w11 >= -0.01)
            {
                float area2 = abs((b11.x - b10.x) * (b01.y - b10.y) - (b01.x - b10.x) * (b11.y - b10.y));
                if (area2 > 1e-6)
                {
                    if (intersectMicroTriangle(tri, b10, b11, b01, matIdx, rayO, rayD,
                                               rayTMin, min(rayTMax, bestT),
                                               microT, microBary, microNormal))
                    {
                        if (microT < bestT)
                        {
                            bestT = microT;
                            hitT = microT;
                            hitBary = microBary;
                            hitGeoNormal = microNormal;
                            found = true;
                        }
                    }
                }
            }
        }
    }

    return found;
}

//=============================================================================
// Main intersection shader - Implements Algorithm 1 from the paper
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
    // Step 1: Intersect ray with bounding prism
    // Compute tight AABB for the entire displaced triangle
    //=========================================================================
    float hMin = 0.0;
    float hMax = DISPLACEMENT_SCALE;

    float3 aabbMin, aabbMax;
    computeRegionAABB(tri, float2(0, 0), float2(1, 1), hMin, hMax, aabbMin, aabbMax);

    float tEntry, tExit;
    if (!rayAABBIntersect(rayOrigin, rayDir, aabbMin, aabbMax, tEntry, tExit))
        return;

    tEntry = max(tEntry, rayTMin);
    tExit = min(tExit, rayTMax);
    if (tEntry >= tExit) return;

    //=========================================================================
    // DIRECT BRUTE FORCE: Tessellate entire triangle
    // (Bypassing hierarchical traversal to debug the 16-hole issue)
    //=========================================================================
    float bestT = rayTMax + 1.0;
    float2 bestBary = float2(0, 0);
    float3 bestGeoNormal = float3(0, 1, 0);
    bool foundHit = false;

    // Resolution based on texture size
    int resolution = min(64, max(8, texSize.x / 8));
    float step = 1.0 / float(resolution);

    // Iterate through barycentric grid using triangular tessellation
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
            float2 b00 = float2(u0, v0);
            float2 b10 = float2(u1, v0);
            float2 b01 = float2(u0, v1);
            float2 b11 = float2(u1, v1);

            // Clamp to triangle boundary (u + v <= 1)
            if (b10.x + b10.y > 1.0) b10 = float2(1.0 - v0, v0);
            if (b01.x + b01.y > 1.0) b01 = float2(u0, 1.0 - u0);
            if (b11.x + b11.y > 1.0) b11 = float2(1.0 - v1, v1);

            float hitT;
            float2 hitBary;
            float3 hitGeoNormal;

            // Triangle 1: b00, b10, b01
            if (intersectMicroTriangle(tri, b00, b10, b01,
                                       matIdx, rayOrigin, rayDir, tEntry, min(tExit, bestT),
                                       hitT, hitBary, hitGeoNormal))
            {
                if (hitT < bestT)
                {
                    bestT = hitT;
                    bestBary = hitBary;
                    bestGeoNormal = hitGeoNormal;
                    foundHit = true;
                }
            }

            // Triangle 2: b10, b11, b01 (only if b11 is inside triangle)
            float w11 = 1.0 - b11.x - b11.y;
            if (w11 >= -0.001 && b11.x >= -0.001 && b11.y >= -0.001)
            {
                float d10 = length(b11 - b10);
                float d01 = length(b11 - b01);
                if (d10 > 0.001 && d01 > 0.001)
                {
                    if (intersectMicroTriangle(tri, b10, b11, b01,
                                               matIdx, rayOrigin, rayDir, tEntry, min(tExit, bestT),
                                               hitT, hitBary, hitGeoNormal))
                    {
                        if (hitT < bestT)
                        {
                            bestT = hitT;
                            bestBary = hitBary;
                            bestGeoNormal = hitGeoNormal;
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
        float2 hitTexUV = baryToTex(tri, bestBary);

        DisplacementHitAttributes attr;
        attr.data.x = asfloat(packUV(hitTexUV));
        attr.data.y = asfloat(packNormal(bestGeoNormal));

        ReportHit(bestT, 0, attr.data);
    }
}
