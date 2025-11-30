/*
 * RMIP V20 - Simple Exit Selection (2 Crossings = No Direction Needed)
 * Paper: "Displacement ray-tracing via inversion and oblong bounding" (SIGGRAPH Asia 2023)
 * Reference: "Tessellation-Free Displacement Mapping for Ray Tracing" (Thonat et al. 2021)
 *
 * V20 Key Changes (from V19):
 * - V16-V19 all tried to determine curve direction - ALL FAILED
 * - Key insight: When numCrossings == 2, we DON'T NEED direction at all!
 * - The exit is simply the crossing edge that's NOT the entry edge
 * - Direction is only needed for:
 *   1. First texel (entryEdge == EDGE_NONE, don't know which is which)
 *   2. Multiple crossings (numCrossings >= 3, curve loops/turns)
 *
 * This DRAMATICALLY simplifies the common case!
 *
 * Key Equations from Paper:
 * - Eq 3: ψ(u,v) = det(P-O, N, D) = (P-O)·(N×D) = 0 (implicit ray projection)
 * - Eq 4: ∇ψ = (ψu, ψv) for gradient computation
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
static const float MARCHING_SCALE = 8.0;
static const int MAX_STACK_SIZE = 32;

// Displacement textures
[[vk::binding(9, 1)]] Texture2D<float> displacementMaps[8];
[[vk::binding(11, 1)]] SamplerState displacementSampler;

// RMIP textures
[[vk::binding(8, 1)]] Texture2DArray<float2> rmipMaps[8];
[[vk::binding(10, 1)]] SamplerState rmipSampler;

[[vk::push_constant]] ConstantBuffer<PathtracePushConstant> pushConst;

//=============================================================================
// Helper: Pack UV and Normal for hit attributes
//=============================================================================
uint packUV(float2 uv)
{
    uint x = uint(saturate(uv.x) * 65535.0);
    uint y = uint(saturate(uv.y) * 65535.0);
    return (x << 16) | y;
}

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

struct DisplacementHitAttributes
{
    float2 data;
};

//=============================================================================
// Triangle data structure
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

float3 getP(Tri tri, float2 bary) { return tri.v0 + bary.x * tri.dPdu + bary.y * tri.dPdv; }
float3 getN(Tri tri, float2 bary) { return tri.n0 + bary.x * tri.dNdu + bary.y * tri.dNdv; }
float2 getT(Tri tri, float2 bary) { return tri.t0 + bary.x * tri.dTdu + bary.y * tri.dTdv; }

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

float2 baryToTex(Tri tri, float2 bary)
{
    return tri.t0 + bary.x * tri.dTdu + bary.y * tri.dTdv;
}

bool baryInTriangle(float2 bary, float eps)
{
    float w = 1.0 - bary.x - bary.y;
    return bary.x >= -eps && bary.y >= -eps && w >= -eps;
}

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
// Bounding Prism Structure (Paper Section 3, Fig 2c)
//
// A prism is formed by extruding the base triangle along displacement normals:
// - 6 vertices total: 3 bottom + 3 top
// - Bottom vertices: P_i + h_min * N_i
// - Top vertices: P_i + h_max * N_i
// - 5 faces: bottom cap, top cap, 3 side quads
//
// Key property: ALL points inside the prism have valid inverse displacement!
// This is why using prism instead of AABB prevents tearing.
//=============================================================================
struct Prism
{
    // Bottom triangle (displaced by h_min)
    float3 b0, b1, b2;
    // Top triangle (displaced by h_max)
    float3 t0, t1, t2;
};

// Construct prism from base triangle and displacement bounds
Prism makePrism(Tri tri, float hMin, float hMax)
{
    Prism prism;

    // Normalized displacement directions at each vertex
    float3 n0 = normalize(tri.n0);
    float3 n1 = normalize(tri.n1);
    float3 n2 = normalize(tri.n2);

    // Bottom vertices (minimum displacement)
    prism.b0 = tri.v0 + n0 * hMin;
    prism.b1 = tri.v1 + n1 * hMin;
    prism.b2 = tri.v2 + n2 * hMin;

    // Top vertices (maximum displacement)
    prism.t0 = tri.v0 + n0 * hMax;
    prism.t1 = tri.v1 + n1 * hMax;
    prism.t2 = tri.v2 + n2 * hMax;

    return prism;
}

//=============================================================================
// Ray-Triangle Intersection (Möller-Trumbore)
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
// Ray-Quad Intersection (split into two triangles)
//=============================================================================
bool rayQuadIntersect(float3 q0, float3 q1, float3 q2, float3 q3,
                      float3 rayO, float3 rayD,
                      out float t)
{
    float2 bary;

    // Try first triangle: q0, q1, q2
    if (rayTriangleIntersect(q0, q1, q2, rayO, rayD, t, bary))
        return true;

    // Try second triangle: q0, q2, q3
    if (rayTriangleIntersect(q0, q2, q3, rayO, rayD, t, bary))
        return true;

    t = 0;
    return false;
}

//=============================================================================
// Ray-Prism Intersection (Paper Algorithm 1, line 2)
//
// A prism has 5 faces:
// 1. Bottom triangular cap (b0, b1, b2)
// 2. Top triangular cap (t0, t1, t2)
// 3. Side quad 0: (b0, b1, t1, t0)
// 4. Side quad 1: (b1, b2, t2, t1)
// 5. Side quad 2: (b2, b0, t0, t2)
//
// Returns entry and exit t values for the ray through the prism.
//=============================================================================
bool rayPrismIntersect(Prism prism, float3 rayO, float3 rayD,
                       out float tEntry, out float tExit)
{
    tEntry = 1e30;
    tExit = -1e30;

    float t;
    float2 bary;
    int hitCount = 0;

    // 1. Bottom triangular cap
    if (rayTriangleIntersect(prism.b0, prism.b1, prism.b2, rayO, rayD, t, bary))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }

    // 2. Top triangular cap
    if (rayTriangleIntersect(prism.t0, prism.t1, prism.t2, rayO, rayD, t, bary))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }

    // 3. Side quad 0: vertices (b0, b1, t1, t0) - edge 0-1
    if (rayQuadIntersect(prism.b0, prism.b1, prism.t1, prism.t0, rayO, rayD, t))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }

    // 4. Side quad 1: vertices (b1, b2, t2, t1) - edge 1-2
    if (rayQuadIntersect(prism.b1, prism.b2, prism.t2, prism.t1, rayO, rayD, t))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }

    // 5. Side quad 2: vertices (b2, b0, t0, t2) - edge 2-0
    if (rayQuadIntersect(prism.b2, prism.b0, prism.t0, prism.t2, rayO, rayD, t))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }

    // Need at least entry and exit (2 hits for convex shape)
    // But ray may originate inside prism (1 hit) or graze edge (0-1 hits)
    if (hitCount >= 1)
    {
        // If only one hit, ray might start inside
        if (hitCount == 1)
        {
            // Check if ray origin is inside prism
            // For simplicity, assume ray starts outside and hits exit
            if (tEntry > 0)
            {
                tExit = tEntry;
                tEntry = 0;
            }
        }
        return tEntry <= tExit && tExit > 0;
    }

    return false;
}

//=============================================================================
// Inverse Displacement Mapping (Eq. 2 from paper)
// Find (u,v) such that displacement line at (u,v) passes through point Q
// Solves: (P(u,v) - Q) × N(u,v) = 0
//
// Key insight: This is guaranteed to converge for points inside the prism!
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
    for (int iter = 0; iter < MAX_NEWTON_ITERS; iter++)
    {
        float3 P = getP(tri, bary);
        float3 N = getN(tri, bary);
        float3 PmQ = P - Q;

        float3 F = cross(PmQ, N);

        if (length(F) < NEWTON_EPS)
            break;

        float3 dFdu = cross(tri.dPdu, N) + cross(PmQ, tri.dNdu);
        float3 dFdv = cross(tri.dPdv, N) + cross(PmQ, tri.dNdv);

        float det = dFdu.x * dFdv.y - dFdu.y * dFdv.x;
        if (abs(det) < 1e-10)
        {
            det = dFdu.x * dFdv.z - dFdu.z * dFdv.x;
            if (abs(det) < 1e-10)
            {
                det = dFdu.y * dFdv.z - dFdu.z * dFdv.y;
                if (abs(det) < 1e-10) break;
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
// Implicit ray projection (Eq. 3): ψ(u,v) = det(P - O, N, D)
//=============================================================================
float psi(Tri tri, float2 bary, float3 rayO, float3 rayD)
{
    float3 P = getP(tri, bary);
    float3 N = getN(tri, bary);
    float3 NxD = cross(N, rayD);
    return dot(P - rayO, NxD);
}

// Partial derivatives of psi (Eq. 4)
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
// V18: Compute ray direction projected into texture (UV) space
//
// The ray has direction D in 3D world space. We want to know which direction
// it's traveling in UV space - this determines how we march through texels.
//
// Method: Project D onto the triangle's tangent plane and express in UV coords.
// - D_proj = D - (D·N)*N (project D onto tangent plane)
// - Solve: D_proj ≈ rayDirUV.x * dPdu + rayDirUV.y * dPdv
// - Use Gram matrix: G = [dPdu·dPdu  dPdu·dPdv; dPdv·dPdu  dPdv·dPdv]
// - rayDirUV = G^(-1) * [D_proj·dPdu, D_proj·dPdv]
//=============================================================================
float2 computeRayDirUV(Tri tri, float3 rayD)
{
    // Triangle normal (average of vertex normals or from edge cross product)
    float3 edge1 = tri.v1 - tri.v0;
    float3 edge2 = tri.v2 - tri.v0;
    float3 N = normalize(cross(edge1, edge2));

    // Project ray direction onto tangent plane
    float3 D_proj = rayD - dot(rayD, N) * N;

    // Gram matrix components
    float g00 = dot(tri.dPdu, tri.dPdu);
    float g01 = dot(tri.dPdu, tri.dPdv);
    float g11 = dot(tri.dPdv, tri.dPdv);

    // Right-hand side
    float b0 = dot(D_proj, tri.dPdu);
    float b1 = dot(D_proj, tri.dPdv);

    // Solve 2x2 system: G * rayDirUV = b
    float det = g00 * g11 - g01 * g01;
    if (abs(det) < 1e-10)
    {
        // Degenerate case: use a simple approximation
        return float2(b0, b1);
    }

    float2 rayDirUV;
    rayDirUV.x = (g11 * b0 - g01 * b1) / det;
    rayDirUV.y = (g00 * b1 - g01 * b0) / det;

    return rayDirUV;
}

//=============================================================================
// V12: Edge direction constants for ψ-guided texel marching (Section 4.4)
//=============================================================================
static const int EDGE_NONE   = -1;
static const int EDGE_LEFT   = 0;   // u decreases (texel to the left)
static const int EDGE_RIGHT  = 1;   // u increases (texel to the right)
static const int EDGE_BOTTOM = 2;   // v decreases (texel below)
static const int EDGE_TOP    = 3;   // v increases (texel above)

//=============================================================================
// V20: Find exit edge - SIMPLE case for 2 crossings (Section 4.4)
//
// Paper Section 4.4: "The sign of the implicit form ψ (3) at each texel corner
// indicates from which edge the ray leaves the texel"
//
// Texel corners:
//   (0,1)-----(1,1)
//     |         |
//     |  texel  |
//     |         |
//   (0,0)-----(1,0)
//
// If ψ changes sign across an edge, the ray curve ψ=0 crosses that edge.
// The exit edge is where the ray LEAVES (not enters) the texel.
//
// V20 KEY INSIGHT: When numCrossings == 2 and we know the entry edge,
// the exit is simply the OTHER crossing edge - NO DIRECTION NEEDED!
// Direction is only used for first texel or when curve makes 3+ crossings.
//=============================================================================
int findExitEdge(float psi00, float psi10, float psi01, float psi11, int entryEdge, float2 curveDir)
{
    // Check which edges have sign changes
    bool crossLeft   = (psi00 * psi01 < 0.0);  // Left edge: between (0,0) and (0,1)
    bool crossRight  = (psi10 * psi11 < 0.0);  // Right edge: between (1,0) and (1,1)
    bool crossBottom = (psi00 * psi10 < 0.0);  // Bottom edge: between (0,0) and (1,0)
    bool crossTop    = (psi01 * psi11 < 0.0);  // Top edge: between (0,1) and (1,1)

    // Count crossings
    int numCrossings = (crossLeft ? 1 : 0) + (crossRight ? 1 : 0) +
                       (crossBottom ? 1 : 0) + (crossTop ? 1 : 0);

    if (numCrossings == 0)
    {
        return EDGE_NONE;
    }

    if (numCrossings == 1)
    {
        // Only one edge - must be the exit
        if (crossLeft)   return EDGE_LEFT;
        if (crossRight)  return EDGE_RIGHT;
        if (crossBottom) return EDGE_BOTTOM;
        if (crossTop)    return EDGE_TOP;
    }

    // V20 FIX: When numCrossings == 2 and we know the entry, exit is the OTHER crossing
    // This is the COMMON CASE and requires NO direction logic!
    if (numCrossings == 2 && entryEdge != EDGE_NONE)
    {
        // Simple: return the crossing edge that's not the entry
        if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
        if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
        if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
        if (crossTop && entryEdge != EDGE_TOP) return EDGE_TOP;
    }

    // Only use direction for: first texel (entryEdge == EDGE_NONE) or 3+ crossings
    // Use curveDir to pick the best exit

    if (abs(curveDir.x) > abs(curveDir.y))
    {
        // Curve moves primarily horizontally in UV space
        if (curveDir.x > 0)
        {
            // Moving right (+u): prefer RIGHT > TOP/BOTTOM > LEFT
            if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
            if (curveDir.y > 0)
            {
                if (crossTop && entryEdge != EDGE_TOP) return EDGE_TOP;
                if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
            }
            else
            {
                if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
                if (crossTop && entryEdge != EDGE_TOP) return EDGE_TOP;
            }
            if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
        }
        else
        {
            // Moving left (-u): prefer LEFT > TOP/BOTTOM > RIGHT
            if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
            if (curveDir.y > 0)
            {
                if (crossTop && entryEdge != EDGE_TOP) return EDGE_TOP;
                if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
            }
            else
            {
                if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
                if (crossTop && entryEdge != EDGE_TOP) return EDGE_TOP;
            }
            if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
        }
    }
    else
    {
        // Curve moves primarily vertically in UV space
        if (curveDir.y > 0)
        {
            // Moving up (+v): prefer TOP > LEFT/RIGHT > BOTTOM
            if (crossTop && entryEdge != EDGE_TOP) return EDGE_TOP;
            if (curveDir.x > 0)
            {
                if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
                if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
            }
            else
            {
                if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
                if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
            }
            if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
        }
        else
        {
            // Moving down (-v): prefer BOTTOM > LEFT/RIGHT > TOP
            if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
            if (curveDir.x > 0)
            {
                if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
                if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
            }
            else
            {
                if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
                if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
            }
            if (crossTop && entryEdge != EDGE_TOP) return EDGE_TOP;
        }
    }

    // Fallback: return any crossing edge (shouldn't reach here normally)
    if (crossRight)  return EDGE_RIGHT;
    if (crossTop)    return EDGE_TOP;
    if (crossLeft)   return EDGE_LEFT;
    if (crossBottom) return EDGE_BOTTOM;

    return EDGE_NONE;
}

//=============================================================================
// V12: Get the opposite edge (for determining entry edge when moving to adjacent texel)
//=============================================================================
int getOppositeEdge(int edge)
{
    switch (edge)
    {
        case EDGE_LEFT:   return EDGE_RIGHT;
        case EDGE_RIGHT:  return EDGE_LEFT;
        case EDGE_BOTTOM: return EDGE_TOP;
        case EDGE_TOP:    return EDGE_BOTTOM;
        default:          return EDGE_NONE;
    }
}

//=============================================================================
// Find turning points in a barycentric region
//=============================================================================
void findTurningPointsInRegion(Tri tri, float2 baryMin, float2 baryMax,
                                float3 rayO, float3 rayD,
                                out float2 turningPts[4], out int numTurning)
{
    numTurning = 0;

    float2 grad00 = psiGrad(tri, float2(0, 0), rayO, rayD);
    float2 grad10 = psiGrad(tri, float2(1, 0), rayO, rayD);
    float2 grad01 = psiGrad(tri, float2(0, 1), rayO, rayD);

    float a_u = grad00.x;
    float b_u = grad10.x - grad00.x;
    float c_u = grad01.x - grad00.x;

    float a_v = grad00.y;
    float b_v = grad10.y - grad00.y;
    float c_v = grad01.y - grad00.y;

    // ψ_u = 0 intersections with region
    if (abs(c_u) > 1e-8)
    {
        float v = -(a_u + b_u * baryMin.x) / c_u;
        if (v >= baryMin.y && v <= baryMax.y && numTurning < 4)
            turningPts[numTurning++] = float2(baryMin.x, v);

        v = -(a_u + b_u * baryMax.x) / c_u;
        if (v >= baryMin.y && v <= baryMax.y && numTurning < 4)
            turningPts[numTurning++] = float2(baryMax.x, v);
    }
    if (abs(b_u) > 1e-8)
    {
        float u = -(a_u + c_u * baryMin.y) / b_u;
        if (u >= baryMin.x && u <= baryMax.x && numTurning < 4)
            turningPts[numTurning++] = float2(u, baryMin.y);

        u = -(a_u + c_u * baryMax.y) / b_u;
        if (u >= baryMin.x && u <= baryMax.x && numTurning < 4)
            turningPts[numTurning++] = float2(u, baryMax.y);
    }

    // ψ_v = 0 intersections
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
// Sample displacement
//=============================================================================
float sampleDisplacement(uint matIdx, float2 texUV)
{
    return displacementMaps[matIdx].SampleLevel(displacementSampler, texUV, 0).r * DISPLACEMENT_SCALE;
}

void getDisplacementBounds(uint matIdx, float2 texMin, float2 texMax, int2 texSize,
                           out float hMin, out float hMax)
{
    // Conservative global bounds (like brute force)
    hMin = 0.0;
    hMax = DISPLACEMENT_SCALE;
}

//=============================================================================
// Ray-AABB intersection (for sub-regions in hierarchical traversal)
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
// AFFINE ARITHMETIC STRUCTURES AND OPERATIONS
// Reference: Appendix A of "Tessellation-Free Displacement Mapping" (Thonat 2021)
//
// An affine form represents: x = x_c + x_u*ε_u + x_v*ε_v + x_K*ε_K
// where ε_u, ε_v, ε_K ∈ [-1, 1] are symbolic variables
//=============================================================================

// Affine form for a scalar value
struct AffineScalar
{
    float c;    // Center value
    float u;    // Coefficient for ε_u (u texture coordinate)
    float v;    // Coefficient for ε_v (v texture coordinate)
    float k;    // Accumulated error (always >= 0)
};

// Affine form for a 3D vector
struct AffineVec3
{
    float3 c;   // Center value
    float3 u;   // Coefficient for ε_u
    float3 v;   // Coefficient for ε_v
    float3 k;   // Accumulated error (per-component, always >= 0)
};

// Create affine scalar from interval [a, b]
AffineScalar affineFromInterval(float a, float b)
{
    AffineScalar af;
    af.c = (a + b) * 0.5;
    af.u = 0;
    af.v = 0;
    af.k = (b - a) * 0.5;
    return af;
}

// Create affine scalar constant
AffineScalar affineConst(float val)
{
    AffineScalar af;
    af.c = val;
    af.u = 0;
    af.v = 0;
    af.k = 0;
    return af;
}

// Create affine vec3 constant
AffineVec3 affineVec3Const(float3 val)
{
    AffineVec3 af;
    af.c = val;
    af.u = float3(0);
    af.v = float3(0);
    af.k = float3(0);
    return af;
}

// Get interval [min, max] from affine scalar (Equation 13)
float2 affineToInterval(AffineScalar af)
{
    float radius = abs(af.u) + abs(af.v) + af.k;
    return float2(af.c - radius, af.c + radius);
}

// Get AABB from affine vec3 (Equation 13)
void affineToAABB(AffineVec3 af, out float3 aabbMin, out float3 aabbMax)
{
    float3 radius = abs(af.u) + abs(af.v) + af.k;
    aabbMin = af.c - radius;
    aabbMax = af.c + radius;
}

// Affine addition: [x] + [y]
AffineScalar affineAdd(AffineScalar x, AffineScalar y)
{
    AffineScalar r;
    r.c = x.c + y.c;
    r.u = x.u + y.u;
    r.v = x.v + y.v;
    r.k = x.k + y.k;
    return r;
}

AffineVec3 affineVec3Add(AffineVec3 x, AffineVec3 y)
{
    AffineVec3 r;
    r.c = x.c + y.c;
    r.u = x.u + y.u;
    r.v = x.v + y.v;
    r.k = x.k + y.k;
    return r;
}

// Affine scalar multiplication: a * [x] where a is constant
AffineScalar affineScale(float a, AffineScalar x)
{
    AffineScalar r;
    r.c = a * x.c;
    r.u = a * x.u;
    r.v = a * x.v;
    r.k = abs(a) * x.k;
    return r;
}

AffineVec3 affineVec3Scale(float a, AffineVec3 x)
{
    AffineVec3 r;
    r.c = a * x.c;
    r.u = a * x.u;
    r.v = a * x.v;
    r.k = abs(a) * x.k;
    return r;
}

// Affine vec3 scaled by constant vec3: a * [x] component-wise
AffineVec3 affineVec3ScaleVec(float3 a, AffineVec3 x)
{
    AffineVec3 r;
    r.c = a * x.c;
    r.u = a * x.u;
    r.v = a * x.v;
    r.k = abs(a) * x.k;
    return r;
}

// Affine multiplication: [x] * [y] (scalar)
// This introduces approximation error!
AffineScalar affineMul(AffineScalar x, AffineScalar y)
{
    AffineScalar r;
    // Center term
    r.c = x.c * y.c;
    // Linear terms
    r.u = x.u * y.c + x.c * y.u;
    r.v = x.v * y.c + x.c * y.v;
    // Error term: includes cross-products of symbolic variables
    float x_rad = abs(x.u) + abs(x.v) + x.k;
    float y_rad = abs(y.u) + abs(y.v) + y.k;
    r.k = abs(x.k * y.c) + abs(x.c * y.k) + x_rad * y_rad;
    return r;
}

// Affine vec3 * scalar: [v] * [s]
AffineVec3 affineVec3MulScalar(AffineVec3 v, AffineScalar s)
{
    AffineVec3 r;
    // Center term
    r.c = v.c * s.c;
    // Linear terms
    r.u = v.u * s.c + v.c * s.u;
    r.v = v.v * s.c + v.c * s.v;
    // Error term
    float3 v_rad = abs(v.u) + abs(v.v) + v.k;
    float s_rad = abs(s.u) + abs(s.v) + s.k;
    r.k = abs(v.k) * abs(s.c) + abs(v.c) * s.k + v_rad * s_rad;
    return r;
}

// Affine dot product: [x] · [y] (vec3)
AffineScalar affineVec3Dot(AffineVec3 x, AffineVec3 y)
{
    AffineScalar r;
    // Center
    r.c = dot(x.c, y.c);
    // Linear terms
    r.u = dot(x.u, y.c) + dot(x.c, y.u);
    r.v = dot(x.v, y.c) + dot(x.c, y.v);
    // Error (conservative)
    float3 x_rad = abs(x.u) + abs(x.v) + x.k;
    float3 y_rad = abs(y.u) + abs(y.v) + y.k;
    r.k = dot(abs(x.k), abs(y.c)) + dot(abs(x.c), y.k) + dot(x_rad, y_rad);
    return r;
}

// Affine squared length: ||[x]||²
AffineScalar affineVec3LengthSq(AffineVec3 x)
{
    return affineVec3Dot(x, x);
}

// Affine reciprocal square root: 1/sqrt([x])
// Uses Chebyshev approximation (Equation 14-15)
AffineScalar affineRsqrt(AffineScalar x)
{
    float2 interval = affineToInterval(x);
    float a = max(interval.x, 1e-6);  // Clamp to avoid division by zero
    float b = max(interval.y, a + 1e-6);

    // f(x) = 1/sqrt(x), compute on interval [a, b]
    float fa = 1.0 / sqrt(a);
    float fb = 1.0 / sqrt(b);

    // Linear approximation: f(x) ≈ α*x + γ
    // Using Chebyshev: α = (fb - fa) / (b - a), γ = (fa + fb) / 2 - α * (a + b) / 2
    float alpha = (fb - fa) / (b - a);
    float mid = (a + b) * 0.5;
    float fmid = 1.0 / sqrt(mid);
    float gamma = fmid;  // Simplified: evaluate at midpoint

    // Error bound: max deviation from linear approximation
    // For 1/sqrt, the function is convex, max error at endpoints or midpoint
    float delta = max(abs(fa - (alpha * a + gamma)), abs(fb - (alpha * b + gamma)));
    delta = max(delta, abs(fmid - (alpha * mid + gamma)));
    // Add extra safety margin for convexity
    delta += 0.1 * abs(fa - fb);

    AffineScalar r;
    r.c = alpha * x.c + gamma;
    r.u = alpha * x.u;
    r.v = alpha * x.v;
    r.k = abs(alpha) * x.k + delta;
    return r;
}

// Affine normalize: [x] / ||[x]||
AffineVec3 affineVec3Normalize(AffineVec3 x)
{
    AffineScalar lenSq = affineVec3LengthSq(x);
    AffineScalar invLen = affineRsqrt(lenSq);
    return affineVec3MulScalar(x, invLen);
}

//=============================================================================
// Compute 3D AABB using Affine Arithmetic (V11)
//
// Given a UV region and displacement bounds, compute tight 3D AABB.
// This replaces the grid sampling approach in V10.1.
//
// The displaced surface is: S(u,v) = P(u,v) + h(u,v) * N̂(u,v)
// - P(u,v) is linear in (u,v) → exact affine form
// - N(u,v) is linear in (u,v) → exact affine form
// - h is an interval → affine form with error
// - N̂ = N/||N|| is non-linear → approximation error
// - S = P + h*N̂ involves multiplication → accumulated error
//=============================================================================
bool computeUVRegionAABB_Affine(Tri tri, float2 uvMin, float2 uvMax,
                                 float hMin, float hMax,
                                 out float3 aabbMin, out float3 aabbMax)
{
    // Convert UV to barycentric center and half-size
    float2 uvCenter = (uvMin + uvMax) * 0.5;
    float2 uvHalfSize = (uvMax - uvMin) * 0.5;

    float2 baryCenter;
    if (!texToBary(tri, uvCenter, baryCenter))
    {
        aabbMin = float3(1e30);
        aabbMax = float3(-1e30);
        return false;
    }

    // Check if barycentric center is reasonably inside triangle
    float w = 1.0 - baryCenter.x - baryCenter.y;
    if (baryCenter.x < -0.5 || baryCenter.y < -0.5 || w < -0.5)
    {
        aabbMin = float3(1e30);
        aabbMax = float3(-1e30);
        return false;
    }

    // Compute barycentric derivatives with respect to UV
    // bary = T_uv^{-1} * (uv - t0) where T_uv = [dTdu, dTdv]
    float det = tri.dTdu.x * tri.dTdv.y - tri.dTdu.y * tri.dTdv.x;
    if (abs(det) < 1e-10)
    {
        aabbMin = float3(1e30);
        aabbMax = float3(-1e30);
        return false;
    }

    // Jacobian of barycentric w.r.t. UV: d(bary)/d(uv)
    float2 dBaryDu = float2(tri.dTdv.y, -tri.dTdu.y) / det;  // ∂bary/∂u_tex
    float2 dBaryDv = float2(-tri.dTdv.x, tri.dTdu.x) / det;  // ∂bary/∂v_tex

    // Affine form for barycentric coordinates
    // bary = baryCenter + dBaryDu * ε_u * uvHalfSize.x + dBaryDv * ε_v * uvHalfSize.y
    float2 baryU = dBaryDu * uvHalfSize.x;  // Coefficient for ε_u
    float2 baryV = dBaryDv * uvHalfSize.y;  // Coefficient for ε_v

    // Create affine form for position P(u,v) = P0 + bary.x * dPdu + bary.y * dPdv
    // This is LINEAR in barycentric, so exact affine form
    AffineVec3 P;
    P.c = tri.v0 + baryCenter.x * tri.dPdu + baryCenter.y * tri.dPdv;
    P.u = baryU.x * tri.dPdu + baryU.y * tri.dPdv;
    P.v = baryV.x * tri.dPdu + baryV.y * tri.dPdv;
    P.k = float3(0);  // Linear, no error

    // Create affine form for normal N(u,v) = N0 + bary.x * dNdu + bary.y * dNdv
    // Also LINEAR in barycentric
    AffineVec3 N;
    N.c = tri.n0 + baryCenter.x * tri.dNdu + baryCenter.y * tri.dNdv;
    N.u = baryU.x * tri.dNdu + baryU.y * tri.dNdv;
    N.v = baryV.x * tri.dNdu + baryV.y * tri.dNdv;
    N.k = float3(0);  // Linear, no error

    // Normalize N to get N̂ (non-linear operation, introduces error)
    AffineVec3 Nhat = affineVec3Normalize(N);

    // Create affine form for height h ∈ [hMin, hMax]
    // Height is independent of u,v (comes from RMIP), so it's an interval
    AffineScalar h = affineFromInterval(hMin, hMax);

    // Compute displaced surface: S = P + h * N̂
    AffineVec3 hNhat = affineVec3MulScalar(Nhat, h);
    AffineVec3 S = affineVec3Add(P, hNhat);

    // Extract AABB from affine form (Equation 13)
    affineToAABB(S, aabbMin, aabbMax);

    // Add small padding for numerical robustness
    float3 padding = (aabbMax - aabbMin) * 0.02 + float3(0.001);
    aabbMin -= padding;
    aabbMax += padding;

    return true;
}

//=============================================================================
// Helper: Add a sample point to AABB if the barycentric is valid
//=============================================================================
bool addSampleToAABB(Tri tri, float2 bary, float hMin, float hMax,
                     inout float3 aabbMin, inout float3 aabbMax)
{
    float w = 1.0 - bary.x - bary.y;
    if (bary.x < -0.02 || bary.y < -0.02 || w < -0.02)
        return false;

    bary = max(float2(0), bary);
    if (bary.x + bary.y > 1.0)
    {
        float s = bary.x + bary.y;
        bary /= s;
    }

    float3 P = getP(tri, bary);
    float3 N = normalize(getN(tri, bary));

    float3 pMin = P + N * hMin;
    float3 pMax = P + N * hMax;

    aabbMin = min(aabbMin, min(pMin, pMax));
    aabbMax = max(aabbMax, max(pMin, pMax));
    return true;
}

//=============================================================================
// Compute 3D AABB for a UV region (for sub-regions in hierarchical traversal)
// V10.1: Use AABB for sub-regions, prism only for initial full-triangle
//=============================================================================
bool computeUVRegionAABB(Tri tri, float2 uvMin, float2 uvMax,
                          float hMin, float hMax,
                          out float3 aabbMin, out float3 aabbMax)
{
    aabbMin = float3(1e30, 1e30, 1e30);
    aabbMax = float3(-1e30, -1e30, -1e30);

    int validSamples = 0;

    // Sample grid within UV region
    const int samples = 8;
    float2 uvStep = (uvMax - uvMin) / float(samples);

    for (int i = 0; i <= samples; i++)
    {
        for (int j = 0; j <= samples; j++)
        {
            float2 uv = uvMin + float2(i, j) * uvStep;
            float2 bary;
            if (!texToBary(tri, uv, bary))
                continue;

            if (addSampleToAABB(tri, bary, hMin, hMax, aabbMin, aabbMax))
                validSamples++;
        }
    }

    // Sample triangle vertices if they fall within UV region
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

    // Sample triangle edge intersections with UV rectangle edges
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

        // Left edge
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

        // Right edge
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

        // Bottom edge
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

        // Top edge
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

    if (validSamples == 0)
        return false;

    // Add padding
    float3 padding = (aabbMax - aabbMin) * 0.05 + float3(0.001, 0.001, 0.001);
    aabbMin -= padding;
    aabbMax += padding;

    return true;
}

//=============================================================================
// Intersect micro-triangle
//=============================================================================
bool intersectMicroTriangle(Tri tri, float2 b0, float2 b1, float2 b2,
                            uint matIdx, float3 rayO, float3 rayD,
                            float tMin, float tMax,
                            out float hitT, out float2 hitBary, out float3 hitGeoNormal)
{
    hitT = tMax + 1.0;
    hitBary = float2(0, 0);
    hitGeoNormal = float3(0, 1, 0);

    float2 tex0 = baryToTex(tri, b0);
    float2 tex1 = baryToTex(tri, b1);
    float2 tex2 = baryToTex(tri, b2);

    float h0 = sampleDisplacement(0, tex0);
    float h1 = sampleDisplacement(0, tex1);
    float h2 = sampleDisplacement(0, tex2);

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

            float3 e1 = p1 - p0;
            float3 e2 = p2 - p0;
            hitGeoNormal = normalize(cross(e1, e2));

            if (dot(hitGeoNormal, rayD) > 0)
                hitGeoNormal = -hitGeoNormal;

            return true;
        }
    }
    return false;
}

//=============================================================================
// UV Bound structure
//=============================================================================
struct UVBound
{
    float2 uvMin;
    float2 uvMax;
};

//=============================================================================
// Check UV region overlap with triangle
//=============================================================================
bool uvRegionOverlapsTriangle(Tri tri, float2 uvMin, float2 uvMax)
{
    float2 bary00, bary10, bary01, bary11;
    texToBary(tri, uvMin, bary00);
    texToBary(tri, float2(uvMax.x, uvMin.y), bary10);
    texToBary(tri, float2(uvMin.x, uvMax.y), bary01);
    texToBary(tri, uvMax, bary11);

    float eps = 0.01;
    bool in00 = bary00.x >= -eps && bary00.y >= -eps && bary00.x + bary00.y <= 1.0 + eps;
    bool in10 = bary10.x >= -eps && bary10.y >= -eps && bary10.x + bary10.y <= 1.0 + eps;
    bool in01 = bary01.x >= -eps && bary01.y >= -eps && bary01.x + bary01.y <= 1.0 + eps;
    bool in11 = bary11.x >= -eps && bary11.y >= -eps && bary11.x + bary11.y <= 1.0 + eps;

    if (in00 || in10 || in01 || in11)
        return true;

    // Check if triangle vertices are inside UV region
    bool triV0InUV = all(tri.t0 >= uvMin) && all(tri.t0 <= uvMax);
    bool triV1InUV = all(tri.t1 >= uvMin) && all(tri.t1 <= uvMax);
    bool triV2InUV = all(tri.t2 >= uvMin) && all(tri.t2 <= uvMax);

    if (triV0InUV || triV1InUV || triV2InUV)
        return true;

    // Check edge intersections
    float2 triEdges[3][2] = {
        { tri.t0, tri.t1 },
        { tri.t1, tri.t2 },
        { tri.t2, tri.t0 }
    };

    for (int i = 0; i < 3; i++)
    {
        float2 eMin = min(triEdges[i][0], triEdges[i][1]);
        float2 eMax = max(triEdges[i][0], triEdges[i][1]);

        if (eMax.x >= uvMin.x && eMin.x <= uvMax.x &&
            eMax.y >= uvMin.y && eMin.y <= uvMax.y)
            return true;
    }

    return false;
}

//=============================================================================
// Compute 3D bounding prism for a UV region
// This is the key change from V9: use PRISM instead of AABB!
//=============================================================================
bool computeUVRegionPrism(Tri tri, float2 uvMin, float2 uvMax,
                           float hMin, float hMax,
                           out Prism prism)
{
    // We need to find the bounding prism for the UV region
    // The prism is defined by the displaced triangle corners

    // For a sub-region of the triangle, we need to find the vertices
    // that bound that region and create a prism from them

    // Sample grid to find barycentric bounds
    float2 baryMin = float2(1e30, 1e30);
    float2 baryMax = float2(-1e30, -1e30);
    int validSamples = 0;

    const int samples = 4;
    float2 uvStep = (uvMax - uvMin) / float(samples);

    for (int i = 0; i <= samples; i++)
    {
        for (int j = 0; j <= samples; j++)
        {
            float2 uv = uvMin + float2(i, j) * uvStep;
            float2 bary;
            if (!texToBary(tri, uv, bary))
                continue;

            // Check if inside triangle
            float w = 1.0 - bary.x - bary.y;
            if (bary.x < -0.02 || bary.y < -0.02 || w < -0.02)
                continue;

            baryMin = min(baryMin, bary);
            baryMax = max(baryMax, bary);
            validSamples++;
        }
    }

    // Also check triangle vertices
    float2 triBary[3] = { float2(0, 0), float2(1, 0), float2(0, 1) };
    for (int k = 0; k < 3; k++)
    {
        float2 uv = baryToTex(tri, triBary[k]);
        if (all(uv >= uvMin - 0.001) && all(uv <= uvMax + 0.001))
        {
            baryMin = min(baryMin, triBary[k]);
            baryMax = max(baryMax, triBary[k]);
            validSamples++;
        }
    }

    if (validSamples == 0)
    {
        // Initialize prism with degenerate values before returning
        prism.b0 = prism.b1 = prism.b2 = tri.v0;
        prism.t0 = prism.t1 = prism.t2 = tri.v0;
        return false;
    }

    // Clamp to valid triangle
    baryMin = max(float2(0, 0), baryMin);
    baryMax = min(float2(1, 1), baryMax);
    if (baryMax.x + baryMax.y > 1.0)
    {
        // Clamp to u+v=1 edge
        float sum = baryMax.x + baryMax.y;
        baryMax = baryMax / sum;
    }

    // Create a triangle from the corners of the barycentric region
    // For a rectangular barycentric region, we take 3 corners that form a valid triangle
    float2 c0 = baryMin;
    float2 c1 = float2(baryMax.x, baryMin.y);
    float2 c2 = float2(baryMin.x, baryMax.y);

    // Clamp each corner
    c0 = clampBary(c0);
    c1 = clampBary(c1);
    c2 = clampBary(c2);

    // Get positions and normals at these corners
    float3 P0 = getP(tri, c0);
    float3 P1 = getP(tri, c1);
    float3 P2 = getP(tri, c2);

    float3 N0 = normalize(getN(tri, c0));
    float3 N1 = normalize(getN(tri, c1));
    float3 N2 = normalize(getN(tri, c2));

    // Create prism
    prism.b0 = P0 + N0 * hMin;
    prism.b1 = P1 + N1 * hMin;
    prism.b2 = P2 + N2 * hMin;

    prism.t0 = P0 + N0 * hMax;
    prism.t1 = P1 + N1 * hMax;
    prism.t2 = P2 + N2 * hMax;

    return true;
}

// Forward declaration for V13 fallback
bool tessellateUVRegion(Tri tri, uint matIdx, float3 rayO, float3 rayD,
                        float2 uvMin, float2 uvMax, float rayTMin, float rayTMax,
                        int2 texSize,
                        out float hitT, out float2 hitBary, out float3 hitGeoNormal);

//=============================================================================
// V21: Brute-Force Texel Testing (Replacing ψ-Guided Marching)
//
// V12-V20 used ψ-guided marching which had fundamental issues:
// 1. Wrong entry texel detection (using AABB entry, not ψ=0 curve entry)
// 2. Numerical precision issues near ψ≈0 causing wrong crossing counts
// 3. Asymmetric fallback (+X/+Y only) missing texels in -X/-Y directions
//
// V21 Solution: Since hierarchical RMIP already narrows to small UV regions
// (typically 2-8 texels wide), simply test ALL texels in the region.
// This is robust, simple, and guaranteed correct.
//
// Algorithm:
// 1. Convert UV bounds to texel coordinates
// 2. Double loop over ALL texels in [texelMin, texelMax]
// 3. For each texel, test its 2 micro-triangles for intersection
// 4. Track the closest hit across all texels
// 5. Return the best hit found
//=============================================================================
bool testAllTexelsInRegion(Tri tri, uint matIdx, float3 rayO, float3 rayD,
                           float2 uvMin, float2 uvMax, float rayTMin, float rayTMax,
                           int2 texSize,
                           out float hitT, out float2 hitBary, out float3 hitGeoNormal)
{
    hitT = rayTMax + 1.0;
    hitBary = float2(0, 0);
    hitGeoNormal = float3(0, 1, 0);

    // Convert UV bounds to texel coordinates
    int2 texelMin = int2(floor(uvMin * float2(texSize)));
    int2 texelMax = int2(ceil(uvMax * float2(texSize)));

    // Clamp to valid range
    texelMin = max(texelMin, int2(0, 0));
    texelMax = min(texelMax, texSize - int2(1, 1));

    if (any(texelMin > texelMax))
        return false;

    float bestT = rayTMax + 1.0;
    bool found = false;

    // V21: Simple double loop over ALL texels - no ψ, no marching, just test everything
    for (int ty = texelMin.y; ty <= texelMax.y; ty++)
    {
        for (int tx = texelMin.x; tx <= texelMax.x; tx++)
        {
            int2 currentTexel = int2(tx, ty);

            // Compute UV coordinates for texel corners
            float2 uv00 = float2(currentTexel) / float2(texSize);
            float2 uv10 = float2(currentTexel + int2(1, 0)) / float2(texSize);
            float2 uv01 = float2(currentTexel + int2(0, 1)) / float2(texSize);
            float2 uv11 = float2(currentTexel + int2(1, 1)) / float2(texSize);

            // Convert to barycentric
            float2 b00, b10, b01, b11;
            texToBary(tri, uv00, b00);
            texToBary(tri, uv10, b10);
            texToBary(tri, uv01, b01);
            texToBary(tri, uv11, b11);

            // Check if any corner is in valid triangle domain
            float eps = 0.01;
            bool valid00 = b00.x >= -eps && b00.y >= -eps && b00.x + b00.y <= 1.0 + eps;
            bool valid10 = b10.x >= -eps && b10.y >= -eps && b10.x + b10.y <= 1.0 + eps;
            bool valid01 = b01.x >= -eps && b01.y >= -eps && b01.x + b01.y <= 1.0 + eps;
            bool valid11 = b11.x >= -eps && b11.y >= -eps && b11.x + b11.y <= 1.0 + eps;

            if (!(valid00 || valid10 || valid01 || valid11))
                continue;

            // Clamp barycentric coordinates for micro-triangle intersection
            b00 = clampBary(b00);
            b10 = clampBary(b10);
            b01 = clampBary(b01);
            b11 = clampBary(b11);

            // Test micro-triangles for intersection
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
// Tessellate UV region (V11 fallback method)
//=============================================================================
bool tessellateUVRegion(Tri tri, uint matIdx, float3 rayO, float3 rayD,
                        float2 uvMin, float2 uvMax, float rayTMin, float rayTMax,
                        int2 texSize,
                        out float hitT, out float2 hitBary, out float3 hitGeoNormal)
{
    hitT = rayTMax + 1.0;
    hitBary = float2(0, 0);
    hitGeoNormal = float3(0, 1, 0);

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
            float2 uv00 = uvMin + float2(iu, iv) * uvStep;
            float2 uv10 = uvMin + float2(iu + 1, iv) * uvStep;
            float2 uv01 = uvMin + float2(iu, iv + 1) * uvStep;
            float2 uv11 = uvMin + float2(iu + 1, iv + 1) * uvStep;

            float2 b00, b10, b01, b11;
            texToBary(tri, uv00, b00);
            texToBary(tri, uv10, b10);
            texToBary(tri, uv01, b01);
            texToBary(tri, uv11, b11);

            float eps = 0.01;
            bool valid00 = b00.x >= -eps && b00.y >= -eps && b00.x + b00.y <= 1.0 + eps;
            bool valid10 = b10.x >= -eps && b10.y >= -eps && b10.x + b10.y <= 1.0 + eps;
            bool valid01 = b01.x >= -eps && b01.y >= -eps && b01.x + b01.y <= 1.0 + eps;
            bool valid11 = b11.x >= -eps && b11.y >= -eps && b11.x + b11.y <= 1.0 + eps;

            if (!valid00 && !valid10 && !valid01 && !valid11)
                continue;

            b00 = clampBary(b00);
            b10 = clampBary(b10);
            b01 = clampBary(b01);
            b11 = clampBary(b11);

            float microT;
            float2 microBary;
            float3 microNormal;

            // Triangle 1
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

            // Triangle 2
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
// Main intersection shader - V17: Entry-Consistent Tangent Direction
//
// V17 Key fix:
// - V16 rotated the problem 90° (ac→bd became ab→cd)
// - Issue: tangent gives ONE direction, but ray could go either way along curve
// - FIX: Flip tangent if it contradicts entry edge direction
//
// Core algorithm:
// - ψ-guided texel marching using sign at corners (Section 4.4)
// - V17: Entry-consistent tangent for correct exit edge selection
// - Affine arithmetic for 3D bounds computation
// - Bounding prism for initial intersection
// - Bound reduction via inverse displacement
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
    // V10: Create full-triangle bounding PRISM and intersect ray with it
    // This is the key difference from V9 - we use PRISM instead of AABB!
    //=========================================================================
    Prism fullPrism = makePrism(tri, 0.0, DISPLACEMENT_SCALE);

    float prismTEntry, prismTExit;
    if (!rayPrismIntersect(fullPrism, rayOrigin, rayDir, prismTEntry, prismTExit))
        return;

    prismTEntry = max(prismTEntry, rayTMin);
    prismTExit = min(prismTExit, rayTMax);
    if (prismTEntry >= prismTExit) return;

    //=========================================================================
    // Project ray-prism intersection points to UV space (Algorithm 1, line 3)
    // Key insight: Since points are INSIDE the prism, inverse displacement
    // is GUARANTEED to converge! This is why prism > AABB.
    //=========================================================================
    float3 Q_entry = rayOrigin + prismTEntry * rayDir;
    float3 Q_exit = rayOrigin + prismTExit * rayDir;

    float2 baryEntry, baryExit;
    bool validEntry = inverseDisplacement(tri, Q_entry, baryEntry);
    bool validExit = inverseDisplacement(tri, Q_exit, baryExit);

    // Initial UV bounds from prism intersection
    float2 triUVMin = min(min(tri.t0, tri.t1), tri.t2);
    float2 triUVMax = max(max(tri.t0, tri.t1), tri.t2);

    float2 initialUVMin = triUVMin;
    float2 initialUVMax = triUVMax;

    if (validEntry && validExit)
    {
        float2 uvEntry = baryToTex(tri, baryEntry);
        float2 uvExit = baryToTex(tri, baryExit);

        // Start with bounds from projected intersection
        initialUVMin = min(uvEntry, uvExit);
        initialUVMax = max(uvEntry, uvExit);

        // Add padding for numerical safety
        float2 uvPadding = (initialUVMax - initialUVMin) * 0.1 + float2(0.01, 0.01);
        initialUVMin = max(triUVMin, initialUVMin - uvPadding);
        initialUVMax = min(triUVMax, initialUVMax + uvPadding);
    }

    //=========================================================================
    // Stack-based hierarchical traversal in UV space
    //=========================================================================
    UVBound stack[MAX_STACK_SIZE];
    int stackPtr = 0;

    stack[stackPtr].uvMin = initialUVMin;
    stack[stackPtr].uvMax = initialUVMax;
    stackPtr++;

    float bestT = rayTMax + 1.0;
    float2 bestBary = float2(0, 0);
    float3 bestGeoNormal = float3(0, 1, 0);
    bool foundHit = false;

    int iterations = 0;

    while (stackPtr > 0 && iterations < MAX_TRAVERSAL_ITERS)
    {
        iterations++;

        stackPtr--;
        UVBound bound = stack[stackPtr];

        if (!uvRegionOverlapsTriangle(tri, bound.uvMin, bound.uvMax))
            continue;

        float2 uvSizeTexels = (bound.uvMax - bound.uvMin) * float2(texSize);
        float maxTexelSize = max(uvSizeTexels.x, uvSizeTexels.y);

        if (maxTexelSize <= MARCHING_SCALE)
        {
            // V21: Test ALL texels in this small region (replaces ψ-guided marching)
            // Brute-force is more robust than ψ-guided and the region is small anyway
            float hitT;
            float2 hitBary;
            float3 hitGeoNormal;

            if (testAllTexelsInRegion(tri, matIdx, rayOrigin, rayDir,
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

        // V11: Use AFFINE ARITHMETIC for sub-region bounds
        // Affine arithmetic provides mathematically guaranteed bounds
        // that never miss extrema (unlike grid sampling in V10.1)
        float hMin, hMax;
        getDisplacementBounds(matIdx, bound.uvMin, bound.uvMax, texSize, hMin, hMax);

        float3 aabbMin, aabbMax;
        if (!computeUVRegionAABB_Affine(tri, bound.uvMin, bound.uvMax, hMin, hMax, aabbMin, aabbMax))
            continue;

        float regionTEntry, regionTExit;
        if (!rayAABBIntersect(rayOrigin, rayDir, aabbMin, aabbMax, regionTEntry, regionTExit))
            continue;

        regionTEntry = max(regionTEntry, rayTMin);
        regionTExit = min(regionTExit, min(rayTMax, bestT));

        if (regionTEntry >= regionTExit)
            continue;

        //=====================================================================
        // Bound reduction via inverse displacement (Paper line 15)
        // Note: AABB points may be outside prism, so inverse displacement
        // may fail. Only apply reduction if both projections succeed.
        //=====================================================================
        float3 Q_entry_region = rayOrigin + regionTEntry * rayDir;
        float3 Q_exit_region = rayOrigin + regionTExit * rayDir;

        float2 baryEntryR, baryExitR;
        bool validEntryR = inverseDisplacement(tri, Q_entry_region, baryEntryR);
        bool validExitR = inverseDisplacement(tri, Q_exit_region, baryExitR);

        if (validEntryR && validExitR)
        {
            float2 uvEntryR = baryToTex(tri, baryEntryR);
            float2 uvExitR = baryToTex(tri, baryExitR);

            float2 projUVMin = min(uvEntryR, uvExitR);
            float2 projUVMax = max(uvEntryR, uvExitR);

            // Find turning points
            float2 baryMin = min(baryEntryR, baryExitR);
            float2 baryMax = max(baryEntryR, baryExitR);
            float2 baryPad = (baryMax - baryMin) * 0.1 + float2(0.01, 0.01);
            baryMin -= baryPad;
            baryMax += baryPad;

            float2 turningPts[4];
            int numTurning;
            findTurningPointsInRegion(tri, baryMin, baryMax, rayOrigin, rayDir, turningPts, numTurning);

            for (int tp = 0; tp < numTurning; tp++)
            {
                float2 tpBary = turningPts[tp];
                float psiVal = psi(tri, tpBary, rayOrigin, rayDir);
                if (abs(psiVal) < 0.1 && baryInTriangle(tpBary, 0.02))
                {
                    float2 tpUV = baryToTex(tri, tpBary);
                    projUVMin = min(projUVMin, tpUV);
                    projUVMax = max(projUVMax, tpUV);
                }
            }

            float2 uvPadding = (bound.uvMax - bound.uvMin) * 0.05 + float2(0.001, 0.001);
            projUVMin -= uvPadding;
            projUVMax += uvPadding;

            bool entryInBounds = all(uvEntryR >= bound.uvMin - 0.01) && all(uvEntryR <= bound.uvMax + 0.01);
            bool exitInBounds = all(uvExitR >= bound.uvMin - 0.01) && all(uvExitR <= bound.uvMax + 0.01);

            if (entryInBounds && exitInBounds)
            {
                bound.uvMin = max(bound.uvMin, projUVMin);
                bound.uvMax = min(bound.uvMax, projUVMax);

                if (any(bound.uvMin >= bound.uvMax))
                    continue;
            }
        }

        // Subdivide
        float2 uvSize = bound.uvMax - bound.uvMin;

        if (stackPtr + 2 <= MAX_STACK_SIZE)
        {
            if (uvSize.x >= uvSize.y)
            {
                float uMid = (bound.uvMin.x + bound.uvMax.x) * 0.5;

                stack[stackPtr].uvMin = float2(uMid, bound.uvMin.y);
                stack[stackPtr].uvMax = bound.uvMax;
                stackPtr++;

                stack[stackPtr].uvMin = bound.uvMin;
                stack[stackPtr].uvMax = float2(uMid, bound.uvMax.y);
                stackPtr++;
            }
            else
            {
                float vMid = (bound.uvMin.y + bound.uvMax.y) * 0.5;

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
