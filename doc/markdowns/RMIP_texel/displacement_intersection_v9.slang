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
static const float MARCHING_SCALE = 8.0;  // Switch to tessellation when UV bound < MARCHING_SCALE texels
static const int MAX_STACK_SIZE = 32;     // Maximum stack depth for hierarchical traversal

// Displacement textures for sampling heights
[[vk::binding(9, 1)]] Texture2D<float> displacementMaps[8];
[[vk::binding(11, 1)]] SamplerState displacementSampler;

// RMIP textures for O(1) min/max queries over rectangular regions
// Each material has a Texture2DArray where layers correspond to different (p,q) levels
[[vk::binding(8, 1)]] Texture2DArray<float2> rmipMaps[8];
[[vk::binding(10, 1)]] SamplerState rmipSampler;

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

// V4.2 FIX: Compute texture-space bounding box for a barycentric region
// IMPORTANT: baryToTex is a linear transform that may NOT be axis-aligned!
// We must check ALL 4 corners to get the correct texture bounds.
void baryRegionToTexBounds(Tri tri, float2 baryMin, float2 baryMax,
                           out float2 texBoundsMin, out float2 texBoundsMax)
{
    // Compute all 4 corners of the barycentric region in texture space
    float2 corner00 = baryToTex(tri, float2(baryMin.x, baryMin.y));
    float2 corner10 = baryToTex(tri, float2(baryMax.x, baryMin.y));
    float2 corner01 = baryToTex(tri, float2(baryMin.x, baryMax.y));
    float2 corner11 = baryToTex(tri, float2(baryMax.x, baryMax.y));

    // Take min/max of all 4 corners
    texBoundsMin = min(min(corner00, corner10), min(corner01, corner11));
    texBoundsMax = max(max(corner00, corner10), max(corner01, corner11));
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
// V8: Find turning points of ray projection curve in a barycentric region
// Turning points are where ψ_u = 0 or ψ_v = 0 (curve changes direction)
// These are critical for properly bounding the ray projection
//=============================================================================
void findTurningPointsInRegion(Tri tri, float2 baryMin, float2 baryMax,
                                float3 rayO, float3 rayD,
                                out float2 turningPts[4], out int numTurning)
{
    numTurning = 0;

    // ψ_u and ψ_v are LINEAR functions in barycentric space
    // Compute coefficients: ψ_u(u,v) = a_u + b_u*u + c_u*v
    float2 grad00 = psiGrad(tri, float2(0, 0), rayO, rayD);
    float2 grad10 = psiGrad(tri, float2(1, 0), rayO, rayD);
    float2 grad01 = psiGrad(tri, float2(0, 1), rayO, rayD);

    // Coefficients for ψ_u = a_u + b_u*u + c_u*v = 0
    float a_u = grad00.x;
    float b_u = grad10.x - grad00.x;
    float c_u = grad01.x - grad00.x;

    // Coefficients for ψ_v = a_v + b_v*u + c_v*v = 0
    float a_v = grad00.y;
    float b_v = grad10.y - grad00.y;
    float c_v = grad01.y - grad00.y;

    // Find where ψ_u = 0 line intersects the bounding region edges
    // Line: a_u + b_u*u + c_u*v = 0, or v = -(a_u + b_u*u) / c_u
    if (abs(c_u) > 1e-8)
    {
        // Check left edge (u = baryMin.x)
        float v = -(a_u + b_u * baryMin.x) / c_u;
        if (v >= baryMin.y && v <= baryMax.y && numTurning < 4)
            turningPts[numTurning++] = float2(baryMin.x, v);

        // Check right edge (u = baryMax.x)
        v = -(a_u + b_u * baryMax.x) / c_u;
        if (v >= baryMin.y && v <= baryMax.y && numTurning < 4)
            turningPts[numTurning++] = float2(baryMax.x, v);
    }
    if (abs(b_u) > 1e-8)
    {
        // Check bottom edge (v = baryMin.y)
        float u = -(a_u + c_u * baryMin.y) / b_u;
        if (u >= baryMin.x && u <= baryMax.x && numTurning < 4)
            turningPts[numTurning++] = float2(u, baryMin.y);

        // Check top edge (v = baryMax.y)
        u = -(a_u + c_u * baryMax.y) / b_u;
        if (u >= baryMin.x && u <= baryMax.x && numTurning < 4)
            turningPts[numTurning++] = float2(u, baryMax.y);
    }

    // Same for ψ_v = 0
    if (abs(c_v) > 1e-8)
    {
        float v = -(a_v + b_v * baryMin.x) / c_v;
        if (v >= baryMin.y && v <= baryMax.y && numTurning < 4)
            turningPts[numTurning++] = float2(baryMin.x, v);

        v = -(a_v + b_v * baryMax.x) / c_v;
        if (v >= baryMin.y && v <= baryMax.y && numTurning < 4)
            turningPts[numTurning++] = float2(baryMax.x, v);
    }
    if (abs(b_v) > 1e-8)
    {
        float u = -(a_v + c_v * baryMin.y) / b_v;
        if (u >= baryMin.x && u <= baryMax.x && numTurning < 4)
            turningPts[numTurning++] = float2(u, baryMin.y);

        u = -(a_v + c_v * baryMax.y) / b_v;
        if (u >= baryMin.x && u <= baryMax.x && numTurning < 4)
            turningPts[numTurning++] = float2(u, baryMax.y);
    }
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
// Get min/max displacement over a texture region
// V5.2: Use conservative global bounds to verify traversal logic works
// Once verified, we can add RMIP queries back
//=============================================================================
void getDisplacementBounds(uint matIdx, float2 texMin, float2 texMax, int2 texSize,
                           out float hMin, out float hMax)
{
    // V5.2: Use conservative global bounds (like brute force)
    // This provides NO culling benefit but should be CORRECT
    // If this works, the traversal logic is correct and RMIP is the issue
    hMin = 0.0;
    hMax = DISPLACEMENT_SCALE;
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

    // V4.2 FIX: Determine tessellation resolution using proper texture bounds
    // baryToTex is a linear transform that may NOT be axis-aligned!
    float2 texBoundsMin, texBoundsMax;
    baryRegionToTexBounds(tri, baryMin, baryMax, texBoundsMin, texBoundsMax);
    float2 texSize2 = (texBoundsMax - texBoundsMin) * float2(texSize);

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
// UV Bound structure for texture-space hierarchical traversal
// V6: Work in TEXTURE SPACE as the paper describes, not barycentric space
//=============================================================================
struct UVBound
{
    float2 uvMin;    // Min UV coordinates
    float2 uvMax;    // Max UV coordinates
};

//=============================================================================
// Check if a UV region overlaps the valid triangle domain
// Converts UV corners to barycentric and checks if any is inside u+v<=1
//=============================================================================
bool uvRegionOverlapsTriangle(Tri tri, float2 uvMin, float2 uvMax)
{
    // Convert all 4 UV corners to barycentric
    float2 bary00, bary10, bary01, bary11;
    texToBary(tri, uvMin, bary00);
    texToBary(tri, float2(uvMax.x, uvMin.y), bary10);
    texToBary(tri, float2(uvMin.x, uvMax.y), bary01);
    texToBary(tri, uvMax, bary11);

    // Check if any corner is inside the triangle (with tolerance)
    float eps = 0.01;

    // A point is inside if u >= 0, v >= 0, and u+v <= 1
    bool in00 = bary00.x >= -eps && bary00.y >= -eps && bary00.x + bary00.y <= 1.0 + eps;
    bool in10 = bary10.x >= -eps && bary10.y >= -eps && bary10.x + bary10.y <= 1.0 + eps;
    bool in01 = bary01.x >= -eps && bary01.y >= -eps && bary01.x + bary01.y <= 1.0 + eps;
    bool in11 = bary11.x >= -eps && bary11.y >= -eps && bary11.x + bary11.y <= 1.0 + eps;

    if (in00 || in10 || in01 || in11)
        return true;

    // Also check if the triangle vertices are inside the UV region
    // This handles cases where UV region fully contains the triangle
    bool triV0InUV = all(tri.t0 >= uvMin) && all(tri.t0 <= uvMax);
    bool triV1InUV = all(tri.t1 >= uvMin) && all(tri.t1 <= uvMax);
    bool triV2InUV = all(tri.t2 >= uvMin) && all(tri.t2 <= uvMax);

    if (triV0InUV || triV1InUV || triV2InUV)
        return true;

    // Check edge intersections (UV rect edges vs triangle edges in UV space)
    // For robustness, check if any triangle edge crosses the UV rectangle
    // This is a conservative check
    float2 triEdges[3][2] = {
        { tri.t0, tri.t1 },
        { tri.t1, tri.t2 },
        { tri.t2, tri.t0 }
    };

    for (int i = 0; i < 3; i++)
    {
        float2 e0 = triEdges[i][0];
        float2 e1 = triEdges[i][1];

        // Check if edge intersects UV rectangle (simple line-rect intersection)
        float2 eMin = min(e0, e1);
        float2 eMax = max(e0, e1);

        // Bounding box intersection
        if (eMax.x >= uvMin.x && eMin.x <= uvMax.x &&
            eMax.y >= uvMin.y && eMin.y <= uvMax.y)
            return true;
    }

    return false;
}

//=============================================================================
// Helper: Add a sample point to AABB if the barycentric is valid
//=============================================================================
bool addSampleToAABB(Tri tri, float2 bary, float hMin, float hMax,
                     inout float3 aabbMin, inout float3 aabbMax)
{
    // Check if inside triangle (with tolerance)
    float w = 1.0 - bary.x - bary.y;
    if (bary.x < -0.02 || bary.y < -0.02 || w < -0.02)
        return false;

    // Clamp to valid range
    bary = max(float2(0), bary);
    if (bary.x + bary.y > 1.0)
    {
        float s = bary.x + bary.y;
        bary /= s;
    }

    // Compute 3D position at both min and max displacement
    float3 P = getP(tri, bary);
    float3 N = normalize(getN(tri, bary));

    float3 pMin = P + N * hMin;
    float3 pMax = P + N * hMax;

    aabbMin = min(aabbMin, min(pMin, pMax));
    aabbMax = max(aabbMax, max(pMin, pMax));
    return true;
}

//=============================================================================
// Compute 3D AABB for a UV region with given displacement bounds
// V6.1: Returns false if UV region doesn't meaningfully overlap triangle
// This fixes the tearing issue caused by fallback AABBs
//=============================================================================
bool computeUVRegionAABB(Tri tri, float2 uvMin, float2 uvMax,
                          float hMin, float hMax,
                          out float3 aabbMin, out float3 aabbMax)
{
    aabbMin = float3(1e30, 1e30, 1e30);
    aabbMax = float3(-1e30, -1e30, -1e30);

    int validSamples = 0;

    // 1. Sample grid within UV region (8x8 for better coverage)
    const int samples = 8;
    float2 uvStep = (uvMax - uvMin) / float(samples);

    for (int i = 0; i <= samples; i++)
    {
        for (int j = 0; j <= samples; j++)
        {
            float2 uv = uvMin + float2(i, j) * uvStep;

            // Convert UV to barycentric
            float2 bary;
            if (!texToBary(tri, uv, bary))
                continue;

            if (addSampleToAABB(tri, bary, hMin, hMax, aabbMin, aabbMax))
                validSamples++;
        }
    }

    // 2. Sample triangle vertices if they fall within UV region
    float2 triUVs[3] = { tri.t0, tri.t1, tri.t2 };
    float2 triBary[3] = { float2(0, 0), float2(1, 0), float2(0, 1) };

    for (int k = 0; k < 3; k++)
    {
        if (all(triUVs[k] >= uvMin - 0.001) && all(triUVs[k] <= uvMax + 0.001))
        {
            if (addSampleToAABB(tri, triBary[k], hMin, hMax, aabbMin, aabbMax))
                validSamples++;
        }
    }

    // 3. Sample triangle edge intersections with UV rectangle edges
    // This catches thin sliver regions along triangle edges
    float2 triEdgeStart[3] = { tri.t0, tri.t1, tri.t2 };
    float2 triEdgeEnd[3] = { tri.t1, tri.t2, tri.t0 };
    float2 edgeBaryStart[3] = { float2(0, 0), float2(1, 0), float2(0, 1) };
    float2 edgeBaryEnd[3] = { float2(1, 0), float2(0, 1), float2(0, 0) };

    for (int e = 0; e < 3; e++)
    {
        float2 e0 = triEdgeStart[e];
        float2 e1 = triEdgeEnd[e];
        float2 b0 = edgeBaryStart[e];
        float2 b1 = edgeBaryEnd[e];

        // Check intersection with UV rect left edge (u = uvMin.x)
        if ((e0.x - uvMin.x) * (e1.x - uvMin.x) <= 0 && e1.x != e0.x)
        {
            float t = (uvMin.x - e0.x) / (e1.x - e0.x);
            float v = e0.y + t * (e1.y - e0.y);
            if (v >= uvMin.y && v <= uvMax.y)
            {
                float2 bary = b0 + t * (b1 - b0);
                if (addSampleToAABB(tri, bary, hMin, hMax, aabbMin, aabbMax))
                    validSamples++;
            }
        }

        // Check intersection with UV rect right edge (u = uvMax.x)
        if ((e0.x - uvMax.x) * (e1.x - uvMax.x) <= 0 && e1.x != e0.x)
        {
            float t = (uvMax.x - e0.x) / (e1.x - e0.x);
            float v = e0.y + t * (e1.y - e0.y);
            if (v >= uvMin.y && v <= uvMax.y)
            {
                float2 bary = b0 + t * (b1 - b0);
                if (addSampleToAABB(tri, bary, hMin, hMax, aabbMin, aabbMax))
                    validSamples++;
            }
        }

        // Check intersection with UV rect bottom edge (v = uvMin.y)
        if ((e0.y - uvMin.y) * (e1.y - uvMin.y) <= 0 && e1.y != e0.y)
        {
            float t = (uvMin.y - e0.y) / (e1.y - e0.y);
            float u = e0.x + t * (e1.x - e0.x);
            if (u >= uvMin.x && u <= uvMax.x)
            {
                float2 bary = b0 + t * (b1 - b0);
                if (addSampleToAABB(tri, bary, hMin, hMax, aabbMin, aabbMax))
                    validSamples++;
            }
        }

        // Check intersection with UV rect top edge (v = uvMax.y)
        if ((e0.y - uvMax.y) * (e1.y - uvMax.y) <= 0 && e1.y != e0.y)
        {
            float t = (uvMax.y - e0.y) / (e1.y - e0.y);
            float u = e0.x + t * (e1.x - e0.x);
            if (u >= uvMin.x && u <= uvMax.x)
            {
                float2 bary = b0 + t * (b1 - b0);
                if (addSampleToAABB(tri, bary, hMin, hMax, aabbMin, aabbMax))
                    validSamples++;
            }
        }
    }

    // If no valid samples, this UV region doesn't meaningfully overlap the triangle
    if (validSamples == 0)
        return false;

    // Add padding
    float3 padding = (aabbMax - aabbMin) * 0.05 + float3(0.001, 0.001, 0.001);
    aabbMin -= padding;
    aabbMax += padding;

    return true;
}

//=============================================================================
// Tessellate a UV region and test for intersection
//=============================================================================
bool tessellateUVRegion(Tri tri, uint matIdx, float3 rayO, float3 rayD,
                        float2 uvMin, float2 uvMax, float rayTMin, float rayTMax,
                        int2 texSize,
                        out float hitT, out float2 hitBary, out float3 hitGeoNormal)
{
    hitT = rayTMax + 1.0;
    hitBary = float2(0, 0);
    hitGeoNormal = float3(0, 1, 0);

    // Determine tessellation resolution based on UV region size in texels
    float2 uvSize = (uvMax - uvMin) * float2(texSize);
    int res = int(max(uvSize.x, uvSize.y)) + 1;
    res = clamp(res, 2, 8);

    float bestT = rayTMax + 1.0;
    bool found = false;

    float2 uvStep = (uvMax - uvMin) / float(res);

    for (int iu = 0; iu < res; iu++)
    {
        for (int iv = 0; iv < res; iv++)
        {
            // UV corners of this cell
            float2 uv00 = uvMin + float2(iu, iv) * uvStep;
            float2 uv10 = uvMin + float2(iu + 1, iv) * uvStep;
            float2 uv01 = uvMin + float2(iu, iv + 1) * uvStep;
            float2 uv11 = uvMin + float2(iu + 1, iv + 1) * uvStep;

            // Convert to barycentric
            float2 b00, b10, b01, b11;
            texToBary(tri, uv00, b00);
            texToBary(tri, uv10, b10);
            texToBary(tri, uv01, b01);
            texToBary(tri, uv11, b11);

            // Check if any corner is inside triangle
            float eps = 0.01;
            bool valid00 = b00.x >= -eps && b00.y >= -eps && b00.x + b00.y <= 1.0 + eps;
            bool valid10 = b10.x >= -eps && b10.y >= -eps && b10.x + b10.y <= 1.0 + eps;
            bool valid01 = b01.x >= -eps && b01.y >= -eps && b01.x + b01.y <= 1.0 + eps;
            bool valid11 = b11.x >= -eps && b11.y >= -eps && b11.x + b11.y <= 1.0 + eps;

            // Skip if all corners are outside
            if (!valid00 && !valid10 && !valid01 && !valid11)
                continue;

            // Clamp barycentric coords to valid triangle domain
            b00 = clampBary(b00);
            b10 = clampBary(b10);
            b01 = clampBary(b01);
            b11 = clampBary(b11);

            float microT;
            float2 microBary;
            float3 microNormal;

            // Triangle 1: b00, b10, b01
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

            // Triangle 2: b10, b11, b01
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
// V9: Find global turning points on the ray projection curve within the triangle
// These are points where ψ_u = 0 or ψ_v = 0 AND the point is ON the ray curve (ψ ≈ 0)
// Returns UV coordinates of turning points for splitting initial bounds
//=============================================================================
void findGlobalTurningPoints(Tri tri, float3 rayO, float3 rayD,
                              out float2 turningUVs[4], out int numTurning)
{
    numTurning = 0;

    // ψ_u and ψ_v are LINEAR in barycentric space
    // Compute coefficients at triangle corners
    float2 grad00 = psiGrad(tri, float2(0, 0), rayO, rayD);
    float2 grad10 = psiGrad(tri, float2(1, 0), rayO, rayD);
    float2 grad01 = psiGrad(tri, float2(0, 1), rayO, rayD);

    // ψ_u(u,v) = a_u + b_u*u + c_u*v = 0 defines a line
    float a_u = grad00.x;
    float b_u = grad10.x - grad00.x;
    float c_u = grad01.x - grad00.x;

    // ψ_v(u,v) = a_v + b_v*u + c_v*v = 0 defines another line
    float a_v = grad00.y;
    float b_v = grad10.y - grad00.y;
    float c_v = grad01.y - grad00.y;

    // Find where ψ_u = 0 line intersects the TRIANGLE edges (not just a rectangle)
    // Triangle edges: u=0 (v∈[0,1]), v=0 (u∈[0,1]), u+v=1

    // Edge 1: u = 0, v ∈ [0, 1]
    if (abs(c_u) > 1e-8)
    {
        float v = -a_u / c_u;
        if (v >= 0 && v <= 1)
        {
            float2 bary = float2(0, v);
            float psiVal = psi(tri, bary, rayO, rayD);
            if (abs(psiVal) < 0.05 && numTurning < 4)  // On the ray curve
            {
                turningUVs[numTurning++] = baryToTex(tri, bary);
            }
        }
    }

    // Edge 2: v = 0, u ∈ [0, 1]
    if (abs(b_u) > 1e-8)
    {
        float u = -a_u / b_u;
        if (u >= 0 && u <= 1)
        {
            float2 bary = float2(u, 0);
            float psiVal = psi(tri, bary, rayO, rayD);
            if (abs(psiVal) < 0.05 && numTurning < 4)
            {
                turningUVs[numTurning++] = baryToTex(tri, bary);
            }
        }
    }

    // Edge 3: u + v = 1, parameterize as u ∈ [0, 1], v = 1 - u
    // ψ_u = a_u + b_u*u + c_u*(1-u) = (a_u + c_u) + (b_u - c_u)*u = 0
    float edge3_a = a_u + c_u;
    float edge3_b = b_u - c_u;
    if (abs(edge3_b) > 1e-8)
    {
        float u = -edge3_a / edge3_b;
        if (u >= 0 && u <= 1)
        {
            float2 bary = float2(u, 1 - u);
            float psiVal = psi(tri, bary, rayO, rayD);
            if (abs(psiVal) < 0.05 && numTurning < 4)
            {
                turningUVs[numTurning++] = baryToTex(tri, bary);
            }
        }
    }

    // Same for ψ_v = 0 line
    // Edge 1: u = 0
    if (abs(c_v) > 1e-8)
    {
        float v = -a_v / c_v;
        if (v >= 0 && v <= 1)
        {
            float2 bary = float2(0, v);
            float psiVal = psi(tri, bary, rayO, rayD);
            if (abs(psiVal) < 0.05 && numTurning < 4)
            {
                turningUVs[numTurning++] = baryToTex(tri, bary);
            }
        }
    }

    // Edge 2: v = 0
    if (abs(b_v) > 1e-8)
    {
        float u = -a_v / b_v;
        if (u >= 0 && u <= 1)
        {
            float2 bary = float2(u, 0);
            float psiVal = psi(tri, bary, rayO, rayD);
            if (abs(psiVal) < 0.05 && numTurning < 4)
            {
                turningUVs[numTurning++] = baryToTex(tri, bary);
            }
        }
    }

    // Edge 3: u + v = 1
    float edge3_av = a_v + c_v;
    float edge3_bv = b_v - c_v;
    if (abs(edge3_bv) > 1e-8)
    {
        float u = -edge3_av / edge3_bv;
        if (u >= 0 && u <= 1)
        {
            float2 bary = float2(u, 1 - u);
            float psiVal = psi(tri, bary, rayO, rayD);
            if (abs(psiVal) < 0.05 && numTurning < 4)
            {
                turningUVs[numTurning++] = baryToTex(tri, bary);
            }
        }
    }
}

//=============================================================================
// Main intersection shader - V9: Initial Turning Point Splitting
// Implements Algorithm 1 with INITIAL bound splitting at turning points (lines 4-5)
// This ensures each initial segment has monotonic ray projection
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
    // V6: Texture-Space Hierarchical Traversal (Algorithm 1 from paper)
    //=========================================================================

    // Step 1: Compute triangle's UV bounding box (texture-space footprint)
    float2 triUVMin = min(min(tri.t0, tri.t1), tri.t2);
    float2 triUVMax = max(max(tri.t0, tri.t1), tri.t2);

    // Step 2: First test full triangle AABB
    float3 fullAABBMin, fullAABBMax;
    if (!computeUVRegionAABB(tri, triUVMin, triUVMax, 0.0, DISPLACEMENT_SCALE, fullAABBMin, fullAABBMax))
        return;  // Should not happen for full triangle

    float tEntry, tExit;
    if (!rayAABBIntersect(rayOrigin, rayDir, fullAABBMin, fullAABBMax, tEntry, tExit))
        return;

    tEntry = max(tEntry, rayTMin);
    tExit = min(tExit, rayTMax);
    if (tEntry >= tExit) return;

    // Step 3: Stack-based hierarchical traversal in UV space
    UVBound stack[MAX_STACK_SIZE];
    int stackPtr = 0;

    //=========================================================================
    // V9: Find global turning points and split initial bounds (Paper lines 4-5)
    // This ensures each initial segment has monotonic ray projection
    //=========================================================================
    float2 turningUVs[4];
    int numTurning;
    findGlobalTurningPoints(tri, rayOrigin, rayDir, turningUVs, numTurning);

    if (numTurning == 0)
    {
        // No turning points - push single initial bound
        stack[stackPtr].uvMin = triUVMin;
        stack[stackPtr].uvMax = triUVMax;
        stackPtr++;
    }
    else
    {
        // Sort turning points by U coordinate for splitting
        // Simple bubble sort (at most 4 elements)
        for (int i = 0; i < numTurning - 1; i++)
        {
            for (int j = i + 1; j < numTurning; j++)
            {
                if (turningUVs[j].x < turningUVs[i].x)
                {
                    float2 temp = turningUVs[i];
                    turningUVs[i] = turningUVs[j];
                    turningUVs[j] = temp;
                }
            }
        }

        // Split initial U range at turning point U coordinates
        // This creates segments with monotonic ray projection
        float prevU = triUVMin.x;
        for (int i = 0; i < numTurning && stackPtr < MAX_STACK_SIZE - 1; i++)
        {
            float splitU = turningUVs[i].x;
            // Only split if turning point U is inside the range
            if (splitU > prevU + 0.001 && splitU < triUVMax.x - 0.001)
            {
                // Push segment [prevU, splitU]
                stack[stackPtr].uvMin = float2(prevU, triUVMin.y);
                stack[stackPtr].uvMax = float2(splitU, triUVMax.y);
                stackPtr++;
                prevU = splitU;
            }
        }

        // Push final segment [prevU, triUVMax.x]
        if (stackPtr < MAX_STACK_SIZE)
        {
            stack[stackPtr].uvMin = float2(prevU, triUVMin.y);
            stack[stackPtr].uvMax = triUVMax;
            stackPtr++;
        }

        // Also split by V coordinate (secondary split)
        // For each existing segment, check if any turning point V splits it
        int originalStackPtr = stackPtr;
        for (int seg = 0; seg < originalStackPtr && stackPtr < MAX_STACK_SIZE - 1; seg++)
        {
            UVBound bound = stack[seg];
            bool wasSplit = false;

            for (int i = 0; i < numTurning; i++)
            {
                float splitV = turningUVs[i].y;
                // Check if this turning point is within this segment's U range
                if (turningUVs[i].x >= bound.uvMin.x && turningUVs[i].x <= bound.uvMax.x)
                {
                    // Check if V splits this segment
                    if (splitV > bound.uvMin.y + 0.001 && splitV < bound.uvMax.y - 0.001)
                    {
                        // Replace original with lower half
                        stack[seg].uvMax.y = splitV;
                        // Push upper half
                        if (stackPtr < MAX_STACK_SIZE)
                        {
                            stack[stackPtr].uvMin = float2(bound.uvMin.x, splitV);
                            stack[stackPtr].uvMax = bound.uvMax;
                            stackPtr++;
                        }
                        wasSplit = true;
                        break;  // Only one V split per segment
                    }
                }
            }
        }
    }

    float bestT = rayTMax + 1.0;
    float2 bestBary = float2(0, 0);
    float3 bestGeoNormal = float3(0, 1, 0);
    bool foundHit = false;

    int iterations = 0;

    while (stackPtr > 0 && iterations < MAX_TRAVERSAL_ITERS)
    {
        iterations++;

        // Pop bound from stack
        stackPtr--;
        UVBound bound = stack[stackPtr];

        // Check if UV region overlaps valid triangle domain
        if (!uvRegionOverlapsTriangle(tri, bound.uvMin, bound.uvMax))
            continue;

        // Compute UV region size in texels
        float2 uvSizeTexels = (bound.uvMax - bound.uvMin) * float2(texSize);
        float maxTexelSize = max(uvSizeTexels.x, uvSizeTexels.y);

        // If small enough, tessellate and test
        if (maxTexelSize <= MARCHING_SCALE)
        {
            float hitT;
            float2 hitBary;
            float3 hitGeoNormal;

            if (tessellateUVRegion(tri, matIdx, rayOrigin, rayDir,
                                   bound.uvMin, bound.uvMax,
                                   rayTMin, min(rayTMax, bestT),
                                   texSize, hitT, hitBary, hitGeoNormal))
            {
                if (hitT < bestT)
                {
                    bestT = hitT;
                    bestBary = hitBary;
                    bestGeoNormal = hitGeoNormal;
                    foundHit = true;
                }
            }
            continue;
        }

        // Query RMIP for displacement bounds over this UV region
        float hMin, hMax;
        getDisplacementBounds(matIdx, bound.uvMin, bound.uvMax, texSize, hMin, hMax);

        // Compute 3D AABB for this UV region
        // V6.1: Skip if UV region doesn't meaningfully overlap triangle
        float3 aabbMin, aabbMax;
        if (!computeUVRegionAABB(tri, bound.uvMin, bound.uvMax, hMin, hMax, aabbMin, aabbMax))
            continue;

        // Test ray against AABB
        float regionTEntry, regionTExit;
        if (!rayAABBIntersect(rayOrigin, rayDir, aabbMin, aabbMax, regionTEntry, regionTExit))
            continue;

        // Clamp to valid ray interval
        regionTEntry = max(regionTEntry, rayTMin);
        regionTExit = min(regionTExit, min(rayTMax, bestT));

        // Early termination if no valid interval
        if (regionTEntry >= regionTExit)
            continue;

        //=====================================================================
        // V8: Bound reduction with turning point detection (Paper lines 4-5, 15)
        // The ray projects to a CURVE in UV space, not just two points
        // Must include turning points (where curve changes direction) in bounds
        //=====================================================================
        float3 Q_entry = rayOrigin + regionTEntry * rayDir;
        float3 Q_exit = rayOrigin + regionTExit * rayDir;

        float2 baryEntry, baryExit;
        bool validEntry = inverseDisplacement(tri, Q_entry, baryEntry);
        bool validExit = inverseDisplacement(tri, Q_exit, baryExit);

        if (validEntry && validExit)
        {
            // Convert barycentric to UV
            float2 uvEntry = baryToTex(tri, baryEntry);
            float2 uvExit = baryToTex(tri, baryExit);

            // Start with bounds from entry/exit
            float2 projUVMin = min(uvEntry, uvExit);
            float2 projUVMax = max(uvEntry, uvExit);

            // V8: Also check turning points in the barycentric region
            // Turning points are where the ray curve has extrema in u or v
            float2 baryMin = min(baryEntry, baryExit);
            float2 baryMax = max(baryEntry, baryExit);

            // Expand slightly to catch nearby turning points
            float2 baryPad = (baryMax - baryMin) * 0.1 + float2(0.01, 0.01);
            baryMin -= baryPad;
            baryMax += baryPad;

            // Find turning points in this region
            float2 turningPts[4];
            int numTurning;
            findTurningPointsInRegion(tri, baryMin, baryMax, rayOrigin, rayDir, turningPts, numTurning);

            // Include turning points in bounds if they're on the ray (ψ ≈ 0)
            for (int tp = 0; tp < numTurning; tp++)
            {
                float2 tpBary = turningPts[tp];
                // Check if this point is actually on the ray projection curve
                float psiVal = psi(tri, tpBary, rayOrigin, rayDir);
                if (abs(psiVal) < 0.1)  // Near the curve
                {
                    // Check if inside triangle
                    if (baryInTriangle(tpBary, 0.02))
                    {
                        float2 tpUV = baryToTex(tri, tpBary);
                        projUVMin = min(projUVMin, tpUV);
                        projUVMax = max(projUVMax, tpUV);
                    }
                }
            }

            // Add padding for numerical safety
            float2 uvPadding = (bound.uvMax - bound.uvMin) * 0.05 + float2(0.001, 0.001);
            projUVMin -= uvPadding;
            projUVMax += uvPadding;

            // Only apply reduction if projected bounds are WITHIN current bounds
            // This prevents bad inverse displacement results from causing tearing
            bool entryInBounds = all(uvEntry >= bound.uvMin - 0.01) && all(uvEntry <= bound.uvMax + 0.01);
            bool exitInBounds = all(uvExit >= bound.uvMin - 0.01) && all(uvExit <= bound.uvMax + 0.01);

            if (entryInBounds && exitInBounds)
            {
                // Intersect with current bounds (can only shrink, never expand)
                bound.uvMin = max(bound.uvMin, projUVMin);
                bound.uvMax = min(bound.uvMax, projUVMax);

                // If bounds became degenerate, skip this region
                if (any(bound.uvMin >= bound.uvMax))
                    continue;
            }
        }

        // Subdivide UV region along longer dimension
        float2 uvSize = bound.uvMax - bound.uvMin;

        if (stackPtr + 2 <= MAX_STACK_SIZE)
        {
            if (uvSize.x >= uvSize.y)
            {
                // Split horizontally (along U)
                float uMid = (bound.uvMin.x + bound.uvMax.x) * 0.5;

                // Push back half first (so front is popped first)
                stack[stackPtr].uvMin = float2(uMid, bound.uvMin.y);
                stack[stackPtr].uvMax = bound.uvMax;
                stackPtr++;

                stack[stackPtr].uvMin = bound.uvMin;
                stack[stackPtr].uvMax = float2(uMid, bound.uvMax.y);
                stackPtr++;
            }
            else
            {
                // Split vertically (along V)
                float vMid = (bound.uvMin.y + bound.uvMax.y) * 0.5;

                // Push back half first
                stack[stackPtr].uvMin = float2(bound.uvMin.x, vMid);
                stack[stackPtr].uvMax = bound.uvMax;
                stackPtr++;

                stack[stackPtr].uvMin = bound.uvMin;
                stack[stackPtr].uvMax = float2(bound.uvMax.x, vMid);
                stackPtr++;
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
