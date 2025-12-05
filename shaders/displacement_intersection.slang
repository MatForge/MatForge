/*
 * RMIP Displacement Intersection Shader (Cleaned V28)
 * Paper: "Displacement ray-tracing via inversion and oblong bounding" (SIGGRAPH Asia 2023)
 *
 * Key Equations from Paper:
 * - Eq 2: (P(u,v) - Q) × N(u,v) = 0 (displacement inversion)
 * - Eq 3: ψ(u,v) = det(P-O, N, D) = (P-O)·(N×D) = 0 (implicit ray projection)
 *
 * Modes (GUI Toggle):
 *    - pushConst.usePsiMarching = 0: Brute force (reliable, tests all texels)
 *    - pushConst.usePsiMarching = 1: ψ-guided marching (experimental)
 */

#include "shaderio.h"
#include "nvshaders/gltf_scene_io.h.slang"
#include "nvshaders/gltf_vertex_access.h.slang"
#include "nvshaders/constants.h.slang"
#include "rmip_common.h.slang"

//=============================================================================
// Constants
//=============================================================================
static const int MAX_NEWTON_ITERS = 8;
static const float NEWTON_EPS = 1e-6;
static const int MAX_TRAVERSAL_ITERS = 512;
static const float MARCHING_SCALE = 8.0;
static const int MAX_STACK_SIZE = 32;
static const float BARY_EPS = 0.05;
static const float PSI_NEAR_ZERO_THRESHOLD = 0.01;

//=============================================================================
// Texture Bindings
//=============================================================================
[[vk::binding(9, 1)]] Texture2D<float> displacementMaps[8];
[[vk::binding(11, 1)]] SamplerState displacementSampler;
[[vk::binding(8, 1)]] Texture2DArray<float2> rmipMaps[8];
[[vk::binding(10, 1)]] SamplerState rmipSampler;
[[vk::binding(12, 1)]] StructuredBuffer<float> displacementFactors;

[[vk::push_constant]] ConstantBuffer<PathtracePushConstant> pushConst;

//=============================================================================
// Helper Functions
//=============================================================================
float getDisplacementScale(uint matIdx)
{
    return displacementFactors[matIdx];
}

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
// Triangle Data Structure
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
//=============================================================================
struct Prism
{
    float3 b0, b1, b2;  // Bottom triangle (displaced by h_min)
    float3 t0, t1, t2;  // Top triangle (displaced by h_max)
};

Prism makePrism(Tri tri, float hMin, float hMax)
{
    Prism prism;
    float3 n0 = normalize(tri.n0);
    float3 n1 = normalize(tri.n1);
    float3 n2 = normalize(tri.n2);

    prism.b0 = tri.v0 + n0 * hMin;
    prism.b1 = tri.v1 + n1 * hMin;
    prism.b2 = tri.v2 + n2 * hMin;
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
// Ray-Quad Intersection
//=============================================================================
bool rayQuadIntersect(float3 q0, float3 q1, float3 q2, float3 q3,
                      float3 rayO, float3 rayD, out float t)
{
    float2 bary;
    if (rayTriangleIntersect(q0, q1, q2, rayO, rayD, t, bary))
        return true;
    if (rayTriangleIntersect(q0, q2, q3, rayO, rayD, t, bary))
        return true;
    t = 0;
    return false;
}

//=============================================================================
// Ray-Prism Intersection (Paper Algorithm 1, line 2)
//=============================================================================
bool rayPrismIntersect(Prism prism, float3 rayO, float3 rayD,
                       out float tEntry, out float tExit)
{
    tEntry = 1e30;
    tExit = -1e30;
    float t;
    float2 bary;
    int hitCount = 0;

    // Bottom cap
    if (rayTriangleIntersect(prism.b0, prism.b1, prism.b2, rayO, rayD, t, bary))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }

    // Top cap
    if (rayTriangleIntersect(prism.t0, prism.t1, prism.t2, rayO, rayD, t, bary))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }

    // Side quads
    if (rayQuadIntersect(prism.b0, prism.b1, prism.t1, prism.t0, rayO, rayD, t))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }
    if (rayQuadIntersect(prism.b1, prism.b2, prism.t2, prism.t1, rayO, rayD, t))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }
    if (rayQuadIntersect(prism.b2, prism.b0, prism.t0, prism.t2, rayO, rayD, t))
    {
        tEntry = min(tEntry, t);
        tExit = max(tExit, t);
        hitCount++;
    }

    if (hitCount >= 1)
    {
        if (hitCount == 1)
        {
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
// Inverse Displacement Mapping (Paper Eq. 2)
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

    // Newton iteration
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
// Implicit Ray Projection ψ (Paper Eq. 3)
// ψ(u,v) = det(P - O, N, D) = (P - O) · (N × D)
//=============================================================================
float psi(Tri tri, float2 bary, float3 rayO, float3 rayD)
{
    float3 P = getP(tri, bary);
    float3 N = getN(tri, bary);
    float3 NxD = cross(N, rayD);
    return dot(P - rayO, NxD);
}

//=============================================================================
// ψ Quadric Coefficients (Paper Section 4.2)
// ψ(u,v) = A*u² + B*v² + C*u*v + D*u + E*v + F
// where (u,v) are barycentric coordinates
//=============================================================================
struct PsiQuadric
{
    float A, B, C, D, E, F;  // Quadric coefficients
    float3 NxD_0, NxD_u, NxD_v;  // Cross products for derivatives
};

PsiQuadric computePsiQuadric(Tri tri, float3 rayO, float3 rayD)
{
    PsiQuadric q;

    // Cross products (constant per ray-triangle pair)
    q.NxD_0 = cross(tri.n0, rayD);
    q.NxD_u = cross(tri.dNdu, rayD);
    q.NxD_v = cross(tri.dNdv, rayD);

    float3 PmO = tri.v0 - rayO;

    // ψ = (P - O) · (N × D)
    // P(u,v) = P0 + u*Pu + v*Pv
    // N(u,v) = N0 + u*Nu + v*Nv
    // N×D = NxD_0 + u*NxD_u + v*NxD_v
    //
    // Expanding: ψ = A*u² + B*v² + C*uv + D*u + E*v + F

    q.A = dot(tri.dPdu, q.NxD_u);
    q.B = dot(tri.dPdv, q.NxD_v);
    q.C = dot(tri.dPdu, q.NxD_v) + dot(tri.dPdv, q.NxD_u);
    q.D = dot(PmO, q.NxD_u) + dot(tri.dPdu, q.NxD_0);
    q.E = dot(PmO, q.NxD_v) + dot(tri.dPdv, q.NxD_0);
    q.F = dot(PmO, q.NxD_0);

    return q;
}

// Evaluate ψ using quadric coefficients
float evalPsiQuadric(PsiQuadric q, float2 bary)
{
    float u = bary.x, v = bary.y;
    return q.A*u*u + q.B*v*v + q.C*u*v + q.D*u + q.E*v + q.F;
}

//=============================================================================
// ψ Partial Derivatives (Paper Eq. 4-5)
// ψ_u = 2A*u + C*v + D = 0  (line in barycentric space)
// ψ_v = C*u + 2B*v + E = 0  (line in barycentric space)
//=============================================================================

// Compute ψ gradient at a point
float2 psiGradient(PsiQuadric q, float2 bary)
{
    float u = bary.x, v = bary.y;
    float psi_u = 2.0 * q.A * u + q.C * v + q.D;
    float psi_v = q.C * u + 2.0 * q.B * v + q.E;
    return float2(psi_u, psi_v);
}

//=============================================================================
// Turning Point Detection (Paper Section 4.2)
// Find where ψ=0 curve intersects ψ_u=0 or ψ_v=0 lines
// These are points where the curve changes principal direction
//=============================================================================
struct TurningPoints
{
    float2 points[4];  // Up to 4 turning points (in barycentric coords)
    int count;
};

// Solve quadratic a*t² + b*t + c = 0
// Returns number of real roots (0, 1, or 2)
int solveQuadratic(float a, float b, float c, out float t0, out float t1)
{
    t0 = 0.0;
    t1 = 0.0;

    if (abs(a) < 1e-10)
    {
        // Linear equation: b*t + c = 0
        if (abs(b) < 1e-10)
            return 0;
        t0 = -c / b;
        return 1;
    }

    float disc = b * b - 4.0 * a * c;
    if (disc < 0.0)
        return 0;

    float sqrtDisc = sqrt(disc);
    float inv2a = 0.5 / a;
    t0 = (-b - sqrtDisc) * inv2a;
    t1 = (-b + sqrtDisc) * inv2a;
    return (disc < 1e-10) ? 1 : 2;
}

// Find turning points in barycentric space within the triangle
TurningPoints findTurningPoints(PsiQuadric q)
{
    TurningPoints tp;
    tp.count = 0;

    // Line 1: ψ_u = 0 → 2A*u + C*v + D = 0
    // If C ≠ 0: v = -(2A*u + D) / C
    // Substitute into ψ = 0: A*u² + B*v² + C*u*v + D*u + E*v + F = 0

    // Try ψ_u = 0 (solve for v in terms of u, then substitute)
    if (abs(q.C) > 1e-10)
    {
        // v = -(2A*u + D) / C = alpha*u + beta
        float alpha = -2.0 * q.A / q.C;
        float beta = -q.D / q.C;

        // Substitute into ψ = A*u² + B*v² + C*u*v + D*u + E*v + F = 0
        // ψ = A*u² + B*(alpha*u + beta)² + C*u*(alpha*u + beta) + D*u + E*(alpha*u + beta) + F
        // ψ = A*u² + B*(alpha²*u² + 2*alpha*beta*u + beta²) + C*(alpha*u² + beta*u) + D*u + E*(alpha*u + beta) + F
        // ψ = (A + B*alpha² + C*alpha)*u² + (2*B*alpha*beta + C*beta + D + E*alpha)*u + (B*beta² + E*beta + F)

        float qa = q.A + q.B * alpha * alpha + q.C * alpha;
        float qb = 2.0 * q.B * alpha * beta + q.C * beta + q.D + q.E * alpha;
        float qc = q.B * beta * beta + q.E * beta + q.F;

        float u0, u1;
        int nRoots = solveQuadratic(qa, qb, qc, u0, u1);

        for (int i = 0; i < nRoots && tp.count < 4; i++)
        {
            float u = (i == 0) ? u0 : u1;
            float v = alpha * u + beta;

            // Check if in triangle (with margin for numerical stability)
            float w = 1.0 - u - v;
            if (u >= -0.1 && v >= -0.1 && w >= -0.1)
            {
                tp.points[tp.count] = float2(u, v);
                tp.count++;
            }
        }
    }
    else if (abs(q.A) > 1e-10)
    {
        // C ≈ 0, use: 2A*u + D = 0 → u = -D / (2A)
        float u = -q.D / (2.0 * q.A);

        // Substitute into ψ = 0: solve for v
        // B*v² + (C*u + E)*v + (A*u² + D*u + F) = 0
        float qa = q.B;
        float qb = q.C * u + q.E;
        float qc = q.A * u * u + q.D * u + q.F;

        float v0, v1;
        int nRoots = solveQuadratic(qa, qb, qc, v0, v1);

        for (int i = 0; i < nRoots && tp.count < 4; i++)
        {
            float v = (i == 0) ? v0 : v1;
            float w = 1.0 - u - v;
            if (u >= -0.1 && v >= -0.1 && w >= -0.1)
            {
                tp.points[tp.count] = float2(u, v);
                tp.count++;
            }
        }
    }

    // Line 2: ψ_v = 0 → C*u + 2B*v + E = 0
    if (abs(q.C) > 1e-10)
    {
        // u = -(2B*v + E) / C = alpha*v + beta
        float alpha = -2.0 * q.B / q.C;
        float beta = -q.E / q.C;

        // Substitute into ψ = 0
        float qa = q.A * alpha * alpha + q.B + q.C * alpha;
        float qb = 2.0 * q.A * alpha * beta + q.C * beta + q.D * alpha + q.E;
        float qc = q.A * beta * beta + q.D * beta + q.F;

        float v0, v1;
        int nRoots = solveQuadratic(qa, qb, qc, v0, v1);

        for (int i = 0; i < nRoots && tp.count < 4; i++)
        {
            float v = (i == 0) ? v0 : v1;
            float u = alpha * v + beta;

            // Check if in triangle and not duplicate
            float w = 1.0 - u - v;
            if (u >= -0.1 && v >= -0.1 && w >= -0.1)
            {
                // Check for duplicates
                bool isDuplicate = false;
                for (int j = 0; j < tp.count; j++)
                {
                    if (length(tp.points[j] - float2(u, v)) < 0.01)
                    {
                        isDuplicate = true;
                        break;
                    }
                }
                if (!isDuplicate)
                {
                    tp.points[tp.count] = float2(u, v);
                    tp.count++;
                }
            }
        }
    }
    else if (abs(q.B) > 1e-10)
    {
        // C ≈ 0, use: 2B*v + E = 0 → v = -E / (2B)
        float v = -q.E / (2.0 * q.B);

        // Substitute into ψ = 0: solve for u
        float qa = q.A;
        float qb = q.C * v + q.D;
        float qc = q.B * v * v + q.E * v + q.F;

        float u0, u1;
        int nRoots = solveQuadratic(qa, qb, qc, u0, u1);

        for (int i = 0; i < nRoots && tp.count < 4; i++)
        {
            float u = (i == 0) ? u0 : u1;
            float w = 1.0 - u - v;
            if (u >= -0.1 && v >= -0.1 && w >= -0.1)
            {
                bool isDuplicate = false;
                for (int j = 0; j < tp.count; j++)
                {
                    if (length(tp.points[j] - float2(u, v)) < 0.01)
                    {
                        isDuplicate = true;
                        break;
                    }
                }
                if (!isDuplicate)
                {
                    tp.points[tp.count] = float2(u, v);
                    tp.count++;
                }
            }
        }
    }

    return tp;
}

// Convert turning points from barycentric to UV space
TurningPoints turningPointsToUV(Tri tri, TurningPoints tpBary)
{
    TurningPoints tpUV;
    tpUV.count = 0;

    for (int i = 0; i < tpBary.count; i++)
    {
        float2 uv = baryToTex(tri, tpBary.points[i]);
        tpUV.points[tpUV.count] = uv;
        tpUV.count++;
    }

    return tpUV;
}

// Check if a turning point is within a UV region
bool turningPointInRegion(float2 tp, float2 uvMin, float2 uvMax)
{
    return tp.x >= uvMin.x && tp.x <= uvMax.x &&
           tp.y >= uvMin.y && tp.y <= uvMax.y;
}

// Get ψ curve direction at a point (perpendicular to gradient)
float2 psiCurveDirection(PsiQuadric q, float2 bary)
{
    float2 grad = psiGradient(q, bary);
    // Curve direction is perpendicular to gradient
    // Rotate 90 degrees: (gx, gy) → (-gy, gx)
    return float2(-grad.y, grad.x);
}

//=============================================================================
// Compute Ray Direction in UV Space
//=============================================================================
float2 computeRayDirUV(Tri tri, float3 rayD)
{
    float3 edge1 = tri.v1 - tri.v0;
    float3 edge2 = tri.v2 - tri.v0;
    float3 N = normalize(cross(edge1, edge2));
    float3 D_proj = rayD - dot(rayD, N) * N;

    float g00 = dot(tri.dPdu, tri.dPdu);
    float g01 = dot(tri.dPdu, tri.dPdv);
    float g11 = dot(tri.dPdv, tri.dPdv);
    float b0 = dot(D_proj, tri.dPdu);
    float b1 = dot(D_proj, tri.dPdv);

    float det = g00 * g11 - g01 * g01;
    if (abs(det) < 1e-10)
        return float2(b0, b1);

    return float2(
        (g11 * b0 - g01 * b1) / det,
        (g00 * b1 - g01 * b0) / det
    );
}

//=============================================================================
// Texel Edge Constants (Paper Section 4.4)
//=============================================================================
static const int EDGE_NONE   = -1;
static const int EDGE_LEFT   = 0;
static const int EDGE_RIGHT  = 1;
static const int EDGE_BOTTOM = 2;
static const int EDGE_TOP    = 3;

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
// Find Exit Edge using ψ signs (Paper Section 4.4)
//=============================================================================
int findExitEdge(float psi00, float psi10, float psi01, float psi11, int entryEdge, float2 curveDir)
{
    bool crossLeft   = (psi00 * psi01 < 0.0);
    bool crossRight  = (psi10 * psi11 < 0.0);
    bool crossBottom = (psi00 * psi10 < 0.0);
    bool crossTop    = (psi01 * psi11 < 0.0);

    int numCrossings = (crossLeft ? 1 : 0) + (crossRight ? 1 : 0) +
                       (crossBottom ? 1 : 0) + (crossTop ? 1 : 0);

    if (numCrossings == 0)
        return EDGE_NONE;

    if (numCrossings == 1)
    {
        if (crossLeft)   return EDGE_LEFT;
        if (crossRight)  return EDGE_RIGHT;
        if (crossBottom) return EDGE_BOTTOM;
        if (crossTop)    return EDGE_TOP;
    }

    // When numCrossings == 2 and we know entry, exit is the OTHER crossing
    if (numCrossings == 2 && entryEdge != EDGE_NONE)
    {
        if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
        if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
        if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
        if (crossTop && entryEdge != EDGE_TOP) return EDGE_TOP;
    }

    // Use curveDir for first texel or 3+ crossings
    if (abs(curveDir.x) > abs(curveDir.y))
    {
        if (curveDir.x > 0)
        {
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
        if (curveDir.y > 0)
        {
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

    // Fallback
    if (crossRight)  return EDGE_RIGHT;
    if (crossTop)    return EDGE_TOP;
    if (crossLeft)   return EDGE_LEFT;
    if (crossBottom) return EDGE_BOTTOM;
    return EDGE_NONE;
}

//=============================================================================
// Displacement Sampling and Bounds
//=============================================================================
float sampleDisplacement(uint matIdx, float2 texUV)
{
    return displacementMaps[matIdx].SampleLevel(displacementSampler, texUV, 0).r * getDisplacementScale(matIdx);
}

void getDisplacementBounds(uint matIdx, float2 texMin, float2 texMax, int2 texSize,
                           out float hMin, out float hMax)
{
    // TODO: Use RMIP for tight rectangular bounds per paper
    // Currently using conservative global bounds
    hMin = 0.0;
    hMax = getDisplacementScale(matIdx);
}

//=============================================================================
// Ray-AABB Intersection
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
// Affine Arithmetic for Tight 3D Bounds
//=============================================================================
struct AffineScalar
{
    float c, u, v, k;
};

struct AffineVec3
{
    float3 c, u, v, k;
};

AffineScalar affineFromInterval(float a, float b)
{
    AffineScalar af;
    af.c = (a + b) * 0.5;
    af.u = 0;
    af.v = 0;
    af.k = (b - a) * 0.5;
    return af;
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

float2 affineToInterval(AffineScalar af)
{
    float radius = abs(af.u) + abs(af.v) + af.k;
    return float2(af.c - radius, af.c + radius);
}

void affineToAABB(AffineVec3 af, out float3 aabbMin, out float3 aabbMax)
{
    float3 radius = abs(af.u) + abs(af.v) + af.k;
    aabbMin = af.c - radius;
    aabbMax = af.c + radius;
}

AffineScalar affineVec3Dot(AffineVec3 x, AffineVec3 y)
{
    AffineScalar r;
    r.c = dot(x.c, y.c);
    r.u = dot(x.u, y.c) + dot(x.c, y.u);
    r.v = dot(x.v, y.c) + dot(x.c, y.v);
    float3 x_rad = abs(x.u) + abs(x.v) + x.k;
    float3 y_rad = abs(y.u) + abs(y.v) + y.k;
    r.k = dot(abs(x.k), abs(y.c)) + dot(abs(x.c), y.k) + dot(x_rad, y_rad);
    return r;
}

AffineScalar affineRsqrt(AffineScalar x)
{
    float2 interval = affineToInterval(x);
    float a = max(interval.x, 1e-6);
    float b = max(interval.y, a + 1e-6);
    float fa = 1.0 / sqrt(a);
    float fb = 1.0 / sqrt(b);
    float alpha = (fb - fa) / (b - a);
    float mid = (a + b) * 0.5;
    float fmid = 1.0 / sqrt(mid);
    float gamma = fmid;
    float delta = max(abs(fa - (alpha * a + gamma)), abs(fb - (alpha * b + gamma)));
    delta = max(delta, abs(fmid - (alpha * mid + gamma)));
    delta += 0.1 * abs(fa - fb);

    AffineScalar r;
    r.c = alpha * x.c + gamma;
    r.u = alpha * x.u;
    r.v = alpha * x.v;
    r.k = abs(alpha) * x.k + delta;
    return r;
}

AffineVec3 affineVec3MulScalar(AffineVec3 v, AffineScalar s)
{
    AffineVec3 r;
    r.c = v.c * s.c;
    r.u = v.u * s.c + v.c * s.u;
    r.v = v.v * s.c + v.c * s.v;
    float3 v_rad = abs(v.u) + abs(v.v) + v.k;
    float s_rad = abs(s.u) + abs(s.v) + s.k;
    r.k = abs(v.k) * abs(s.c) + abs(v.c) * s.k + v_rad * s_rad;
    return r;
}

AffineVec3 affineVec3Normalize(AffineVec3 x)
{
    AffineScalar lenSq = affineVec3Dot(x, x);
    AffineScalar invLen = affineRsqrt(lenSq);
    return affineVec3MulScalar(x, invLen);
}

//=============================================================================
// Compute 3D AABB using Affine Arithmetic
//=============================================================================
bool computeUVRegionAABB_Affine(Tri tri, float2 uvMin, float2 uvMax,
                                 float hMin, float hMax,
                                 out float3 aabbMin, out float3 aabbMax)
{
    float2 uvCenter = (uvMin + uvMax) * 0.5;
    float2 uvHalfSize = (uvMax - uvMin) * 0.5;

    float2 baryCenter;
    if (!texToBary(tri, uvCenter, baryCenter))
    {
        aabbMin = float3(1e30);
        aabbMax = float3(-1e30);
        return false;
    }

    float w = 1.0 - baryCenter.x - baryCenter.y;
    if (baryCenter.x < -0.5 || baryCenter.y < -0.5 || w < -0.5)
    {
        aabbMin = float3(1e30);
        aabbMax = float3(-1e30);
        return false;
    }

    float det = tri.dTdu.x * tri.dTdv.y - tri.dTdu.y * tri.dTdv.x;
    if (abs(det) < 1e-10)
    {
        aabbMin = float3(1e30);
        aabbMax = float3(-1e30);
        return false;
    }

    float2 dBaryDu = float2(tri.dTdv.y, -tri.dTdu.y) / det;
    float2 dBaryDv = float2(-tri.dTdv.x, tri.dTdu.x) / det;
    float2 baryU = dBaryDu * uvHalfSize.x;
    float2 baryV = dBaryDv * uvHalfSize.y;

    AffineVec3 P;
    P.c = tri.v0 + baryCenter.x * tri.dPdu + baryCenter.y * tri.dPdv;
    P.u = baryU.x * tri.dPdu + baryU.y * tri.dPdv;
    P.v = baryV.x * tri.dPdu + baryV.y * tri.dPdv;
    P.k = float3(0);

    AffineVec3 N;
    N.c = tri.n0 + baryCenter.x * tri.dNdu + baryCenter.y * tri.dNdv;
    N.u = baryU.x * tri.dNdu + baryU.y * tri.dNdv;
    N.v = baryV.x * tri.dNdu + baryV.y * tri.dNdv;
    N.k = float3(0);

    AffineVec3 Nhat = affineVec3Normalize(N);
    AffineScalar h = affineFromInterval(hMin, hMax);
    AffineVec3 hNhat = affineVec3MulScalar(Nhat, h);
    AffineVec3 S = affineVec3Add(P, hNhat);

    affineToAABB(S, aabbMin, aabbMax);
    float3 padding = (aabbMax - aabbMin) * 0.02 + float3(0.001);
    aabbMin -= padding;
    aabbMax += padding;

    return true;
}

//=============================================================================
// Micro-Triangle Intersection
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

    float h0 = sampleDisplacement(matIdx, tex0);
    float h1 = sampleDisplacement(matIdx, tex1);
    float h2 = sampleDisplacement(matIdx, tex2);

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

            float3 baseNormal = normalize(N0 * w + N1 * triB.x + N2 * triB.y);
            if (dot(hitGeoNormal, baseNormal) < 0)
                hitGeoNormal = -hitGeoNormal;

            return true;
        }
    }
    return false;
}

//=============================================================================
// UV Bound Structure
//=============================================================================
struct UVBound
{
    float2 uvMin;
    float2 uvMax;
};

//=============================================================================
// Check UV Region Overlap with Triangle
//=============================================================================
bool uvRegionOverlapsTriangle(Tri tri, float2 uvMin, float2 uvMax)
{
    float2 bary00, bary10, bary01, bary11;
    texToBary(tri, uvMin, bary00);
    texToBary(tri, float2(uvMax.x, uvMin.y), bary10);
    texToBary(tri, float2(uvMin.x, uvMax.y), bary01);
    texToBary(tri, uvMax, bary11);

    bool in00 = bary00.x >= -BARY_EPS && bary00.y >= -BARY_EPS && bary00.x + bary00.y <= 1.0 + BARY_EPS;
    bool in10 = bary10.x >= -BARY_EPS && bary10.y >= -BARY_EPS && bary10.x + bary10.y <= 1.0 + BARY_EPS;
    bool in01 = bary01.x >= -BARY_EPS && bary01.y >= -BARY_EPS && bary01.x + bary01.y <= 1.0 + BARY_EPS;
    bool in11 = bary11.x >= -BARY_EPS && bary11.y >= -BARY_EPS && bary11.x + bary11.y <= 1.0 + BARY_EPS;

    if (in00 || in10 || in01 || in11)
        return true;

    bool triV0InUV = all(tri.t0 >= uvMin) && all(tri.t0 <= uvMax);
    bool triV1InUV = all(tri.t1 >= uvMin) && all(tri.t1 <= uvMax);
    bool triV2InUV = all(tri.t2 >= uvMin) && all(tri.t2 <= uvMax);

    if (triV0InUV || triV1InUV || triV2InUV)
        return true;

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
// Brute Force Texel Testing (Reliable Fallback)
//=============================================================================
bool testAllTexelsInRegion(Tri tri, uint matIdx, float3 rayO, float3 rayD,
                           float2 uvMin, float2 uvMax, float rayTMin, float rayTMax,
                           int2 texSize,
                           out float hitT, out float2 hitBary, out float3 hitGeoNormal)
{
    hitT = rayTMax + 1.0;
    hitBary = float2(0, 0);
    hitGeoNormal = float3(0, 1, 0);

    int2 texelMin = int2(floor(uvMin * float2(texSize)));
    int2 texelMax = int2(ceil(uvMax * float2(texSize)));
    texelMin = max(texelMin, int2(0, 0));
    texelMax = min(texelMax, texSize - int2(1, 1));

    if (any(texelMin > texelMax))
        return false;

    float bestT = rayTMax + 1.0;
    bool found = false;

    for (int ty = texelMin.y; ty <= texelMax.y; ty++)
    {
        for (int tx = texelMin.x; tx <= texelMax.x; tx++)
        {
            int2 currentTexel = int2(tx, ty);

            float2 uv00 = float2(currentTexel) / float2(texSize);
            float2 uv10 = float2(currentTexel + int2(1, 0)) / float2(texSize);
            float2 uv01 = float2(currentTexel + int2(0, 1)) / float2(texSize);
            float2 uv11 = float2(currentTexel + int2(1, 1)) / float2(texSize);

            float2 b00, b10, b01, b11;
            texToBary(tri, uv00, b00);
            texToBary(tri, uv10, b10);
            texToBary(tri, uv01, b01);
            texToBary(tri, uv11, b11);

            bool valid00 = b00.x >= -BARY_EPS && b00.y >= -BARY_EPS && b00.x + b00.y <= 1.0 + BARY_EPS;
            bool valid10 = b10.x >= -BARY_EPS && b10.y >= -BARY_EPS && b10.x + b10.y <= 1.0 + BARY_EPS;
            bool valid01 = b01.x >= -BARY_EPS && b01.y >= -BARY_EPS && b01.x + b01.y <= 1.0 + BARY_EPS;
            bool valid11 = b11.x >= -BARY_EPS && b11.y >= -BARY_EPS && b11.x + b11.y <= 1.0 + BARY_EPS;

            if (!(valid00 || valid10 || valid01 || valid11))
                continue;

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
            if (w11 >= -BARY_EPS)
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
// ψ-Guided Texel Marching (Paper Section 4.4)
// Enhanced with turning point detection (Paper Section 4.2)
//=============================================================================
bool texelMarchWithPsi(Tri tri, uint matIdx, float3 rayO, float3 rayD,
                       float2 uvMin, float2 uvMax, float rayTMin, float rayTMax,
                       int2 texSize, float2 rayDirUV,
                       out float hitT, out float2 hitBary, out float3 hitGeoNormal)
{
    hitT = rayTMax + 1.0;
    hitBary = float2(0, 0);
    hitGeoNormal = float3(0, 1, 0);

    // Compute ψ quadric coefficients (Paper Section 4.2)
    PsiQuadric psiQ = computePsiQuadric(tri, rayO, rayD);

    // Find turning points (Paper Section 4.2, Eq. 4-5)
    // These are where ψ_u = 0 or ψ_v = 0 intersects ψ = 0
    TurningPoints tpBary = findTurningPoints(psiQ);
    TurningPoints tpUV = turningPointsToUV(tri, tpBary);

    // Entry detection via inverse_displacement (Paper Section 4.1)
    float3 Q_entry = rayO + rayTMin * rayD;
    float3 Q_exit = rayO + rayTMax * rayD;

    float2 baryEntry, baryExit;
    bool validEntry = inverseDisplacement(tri, Q_entry, baryEntry);
    bool validExit = inverseDisplacement(tri, Q_exit, baryExit);

    float2 uvEntry = baryToTex(tri, baryEntry);
    float2 uvExit = baryToTex(tri, baryExit);

    // Bound refinement (Paper Algorithm 1 line 15)
    // Also expand bounds to include turning points (Paper Section 4.2)
    float2 refinedUvMin = uvMin;
    float2 refinedUvMax = uvMax;

    if (validEntry && validExit)
    {
        float2 rayUvMin = min(uvEntry, uvExit);
        float2 rayUvMax = max(uvEntry, uvExit);

        // Expand bounds to include any turning points within the region
        // This ensures the bounding rectangle contains the entire ψ curve
        for (int i = 0; i < tpUV.count; i++)
        {
            if (turningPointInRegion(tpUV.points[i], uvMin, uvMax))
            {
                rayUvMin = min(rayUvMin, tpUV.points[i]);
                rayUvMax = max(rayUvMax, tpUV.points[i]);
            }
        }

        float2 padding = float2(1.0) / float2(texSize);
        refinedUvMin = max(uvMin, rayUvMin - padding);
        refinedUvMax = min(uvMax, rayUvMax + padding);
    }

    int2 texelMin = int2(floor(refinedUvMin * float2(texSize)));
    int2 texelMax = int2(floor(refinedUvMax * float2(texSize)));
    texelMin = max(texelMin, int2(0, 0));
    texelMax = min(texelMax, texSize - int2(1, 1));

    if (any(texelMin > texelMax))
        return false;

    // Find entry texel using inverse displacement or ray direction
    int2 currentTexel;
    float2 curveDir = rayDirUV;  // Initial curve direction estimate

    if (validEntry)
    {
        float2 clampedEntryUV = clamp(uvEntry, refinedUvMin, refinedUvMax);
        currentTexel = int2(floor(clampedEntryUV * float2(texSize)));
        currentTexel = clamp(currentTexel, texelMin, texelMax);

        // Use ψ gradient for initial curve direction (Paper Section 4.2)
        // Curve direction is perpendicular to gradient
        float2 grad = psiGradient(psiQ, baryEntry);
        if (length(grad) > 1e-6)
        {
            // Convert barycentric gradient to UV direction
            float2 curveDirBary = psiCurveDirection(psiQ, baryEntry);
            // Transform to UV space (approximate)
            curveDir = float2(
                curveDirBary.x * tri.dTdu.x + curveDirBary.y * tri.dTdv.x,
                curveDirBary.x * tri.dTdu.y + curveDirBary.y * tri.dTdv.y
            );
            // Ensure we're going from entry toward exit
            if (validExit && dot(curveDir, uvExit - uvEntry) < 0)
                curveDir = -curveDir;
        }
    }
    else
    {
        if (rayDirUV.x >= 0 && rayDirUV.y >= 0)
            currentTexel = texelMin;
        else if (rayDirUV.x >= 0 && rayDirUV.y < 0)
            currentTexel = int2(texelMin.x, texelMax.y);
        else if (rayDirUV.x < 0 && rayDirUV.y >= 0)
            currentTexel = int2(texelMax.x, texelMin.y);
        else
            currentTexel = texelMax;
    }

    int entryEdge = EDGE_NONE;
    if (abs(curveDir.x) >= abs(curveDir.y))
        entryEdge = (curveDir.x >= 0) ? EDGE_LEFT : EDGE_RIGHT;
    else
        entryEdge = (curveDir.y >= 0) ? EDGE_BOTTOM : EDGE_TOP;

    float bestT = rayTMax + 1.0;
    bool found = false;
    int maxIters = (texelMax.x - texelMin.x + 1) * (texelMax.y - texelMin.y + 1) + 4;

    for (int iter = 0; iter < maxIters; iter++)
    {
        if (currentTexel.x < texelMin.x || currentTexel.x > texelMax.x ||
            currentTexel.y < texelMin.y || currentTexel.y > texelMax.y)
            break;

        float2 uv00 = float2(currentTexel) / float2(texSize);
        float2 uv10 = float2(currentTexel + int2(1, 0)) / float2(texSize);
        float2 uv01 = float2(currentTexel + int2(0, 1)) / float2(texSize);
        float2 uv11 = float2(currentTexel + int2(1, 1)) / float2(texSize);

        float2 b00, b10, b01, b11;
        texToBary(tri, uv00, b00);
        texToBary(tri, uv10, b10);
        texToBary(tri, uv01, b01);
        texToBary(tri, uv11, b11);

        float2 b00_orig = b00, b10_orig = b10, b01_orig = b01, b11_orig = b11;

        bool valid00 = b00.x >= -BARY_EPS && b00.y >= -BARY_EPS && b00.x + b00.y <= 1.0 + BARY_EPS;
        bool valid10 = b10.x >= -BARY_EPS && b10.y >= -BARY_EPS && b10.x + b10.y <= 1.0 + BARY_EPS;
        bool valid01 = b01.x >= -BARY_EPS && b01.y >= -BARY_EPS && b01.x + b01.y <= 1.0 + BARY_EPS;
        bool valid11 = b11.x >= -BARY_EPS && b11.y >= -BARY_EPS && b11.x + b11.y <= 1.0 + BARY_EPS;

        if (valid00 || valid10 || valid01 || valid11)
        {
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
            if (w11 >= -BARY_EPS)
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

        // Compute ψ at valid corners using quadric for efficiency
        // Use NaN-safe values for invalid corners to avoid false crossings
        float psi00 = valid00 ? evalPsiQuadric(psiQ, b00_orig) : 1e30;
        float psi10 = valid10 ? evalPsiQuadric(psiQ, b10_orig) : 1e30;
        float psi01 = valid01 ? evalPsiQuadric(psiQ, b01_orig) : 1e30;
        float psi11 = valid11 ? evalPsiQuadric(psiQ, b11_orig) : 1e30;

        int validCount = (valid00 ? 1 : 0) + (valid10 ? 1 : 0) + (valid01 ? 1 : 0) + (valid11 ? 1 : 0);

        // Check if a turning point exists in this texel
        float2 texelUvMin = float2(currentTexel) / float2(texSize);
        float2 texelUvMax = float2(currentTexel + int2(1, 1)) / float2(texSize);
        bool hasTurningPoint = false;
        for (int tpi = 0; tpi < tpUV.count; tpi++)
        {
            if (turningPointInRegion(tpUV.points[tpi], texelUvMin, texelUvMax))
            {
                hasTurningPoint = true;
                break;
            }
        }

        // Update curve direction at texel center using ψ gradient
        float2 texelCenterBary;
        float2 texelCenterUV = (texelUvMin + texelUvMax) * 0.5;
        if (texToBary(tri, texelCenterUV, texelCenterBary))
        {
            float2 grad = psiGradient(psiQ, texelCenterBary);
            if (length(grad) > 1e-6)
            {
                float2 localCurveDirBary = psiCurveDirection(psiQ, texelCenterBary);
                float2 localCurveDir = float2(
                    localCurveDirBary.x * tri.dTdu.x + localCurveDirBary.y * tri.dTdv.x,
                    localCurveDirBary.x * tri.dTdu.y + localCurveDirBary.y * tri.dTdv.y
                );
                // Maintain consistent direction
                if (dot(localCurveDir, curveDir) < 0)
                    localCurveDir = -localCurveDir;
                curveDir = localCurveDir;
            }
        }

        // DDA fallback for insufficient valid corners
        if (validCount < 2)
        {
            if (abs(curveDir.x) >= abs(curveDir.y))
            {
                int dx = (curveDir.x >= 0) ? 1 : -1;
                if (currentTexel.x + dx >= texelMin.x && currentTexel.x + dx <= texelMax.x)
                {
                    currentTexel.x += dx;
                    entryEdge = (dx > 0) ? EDGE_LEFT : EDGE_RIGHT;
                }
                else
                {
                    int dy = (curveDir.y >= 0) ? 1 : -1;
                    if (currentTexel.y + dy >= texelMin.y && currentTexel.y + dy <= texelMax.y)
                    {
                        currentTexel.y += dy;
                        entryEdge = (dy > 0) ? EDGE_BOTTOM : EDGE_TOP;
                    }
                    else break;
                }
            }
            else
            {
                int dy = (curveDir.y >= 0) ? 1 : -1;
                if (currentTexel.y + dy >= texelMin.y && currentTexel.y + dy <= texelMax.y)
                {
                    currentTexel.y += dy;
                    entryEdge = (dy > 0) ? EDGE_BOTTOM : EDGE_TOP;
                }
                else
                {
                    int dx = (curveDir.x >= 0) ? 1 : -1;
                    if (currentTexel.x + dx >= texelMin.x && currentTexel.x + dx <= texelMax.x)
                    {
                        currentTexel.x += dx;
                        entryEdge = (dx > 0) ? EDGE_LEFT : EDGE_RIGHT;
                    }
                    else break;
                }
            }
            continue;
        }

        // Scale threshold relative to ψ magnitude (Paper Section 4.2)
        float maxAbsPsi = max(max(abs(psi00), abs(psi10)), max(abs(psi01), abs(psi11)));
        float avgAbsPsi = (abs(psi00) + abs(psi10) + abs(psi01) + abs(psi11)) / float(validCount);
        bool psiDegenerate = maxAbsPsi < PSI_NEAR_ZERO_THRESHOLD * avgAbsPsi ||
                             maxAbsPsi < PSI_NEAR_ZERO_THRESHOLD * 0.001;

        // At turning points, the curve changes direction - be more careful
        if (hasTurningPoint)
        {
            // At turning points, trust the sign pattern less
            // Use gradient direction as primary guide
            psiDegenerate = true;
        }

        int exitEdge = findExitEdge(psi00, psi10, psi01, psi11, entryEdge, curveDir);

        // DDA fallback for no exit or degenerate ψ
        if (exitEdge == EDGE_NONE || psiDegenerate)
        {
            if (abs(curveDir.x) >= abs(curveDir.y))
            {
                int dx = (curveDir.x >= 0) ? 1 : -1;
                if (currentTexel.x + dx >= texelMin.x && currentTexel.x + dx <= texelMax.x)
                {
                    currentTexel.x += dx;
                    entryEdge = (dx > 0) ? EDGE_LEFT : EDGE_RIGHT;
                }
                else
                {
                    int dy = (curveDir.y >= 0) ? 1 : -1;
                    if (currentTexel.y + dy >= texelMin.y && currentTexel.y + dy <= texelMax.y)
                    {
                        currentTexel.y += dy;
                        entryEdge = (dy > 0) ? EDGE_BOTTOM : EDGE_TOP;
                    }
                    else break;
                }
            }
            else
            {
                int dy = (curveDir.y >= 0) ? 1 : -1;
                if (currentTexel.y + dy >= texelMin.y && currentTexel.y + dy <= texelMax.y)
                {
                    currentTexel.y += dy;
                    entryEdge = (dy > 0) ? EDGE_BOTTOM : EDGE_TOP;
                }
                else
                {
                    int dx = (curveDir.x >= 0) ? 1 : -1;
                    if (currentTexel.x + dx >= texelMin.x && currentTexel.x + dx <= texelMax.x)
                    {
                        currentTexel.x += dx;
                        entryEdge = (dx > 0) ? EDGE_LEFT : EDGE_RIGHT;
                    }
                    else break;
                }
            }
            continue;
        }

        // Move to adjacent texel
        switch (exitEdge)
        {
            case EDGE_LEFT:   currentTexel.x--; break;
            case EDGE_RIGHT:  currentTexel.x++; break;
            case EDGE_BOTTOM: currentTexel.y--; break;
            case EDGE_TOP:    currentTexel.y++; break;
        }
        entryEdge = getOppositeEdge(exitEdge);
    }

    return found;
}

//=============================================================================
// Leaf Region Tester (Dispatches to brute force or ψ-marching)
//=============================================================================
bool testLeafRegion(Tri tri, uint matIdx, float3 rayO, float3 rayD,
                    float2 uvMin, float2 uvMax, float rayTMin, float rayTMax,
                    int2 texSize,
                    out float hitT, out float2 hitBary, out float3 hitGeoNormal)
{
    hitT = rayTMax + 1.0;
    hitBary = float2(0, 0);
    hitGeoNormal = float3(0, 1, 0);

    if (pushConst.usePsiMarching == 0)
    {
        return testAllTexelsInRegion(tri, matIdx, rayO, rayD,
                                     uvMin, uvMax, rayTMin, rayTMax,
                                     texSize, hitT, hitBary, hitGeoNormal);
    }

    float2 rayDirUV = computeRayDirUV(tri, rayD);
    return texelMarchWithPsi(tri, matIdx, rayO, rayD,
                             uvMin, uvMax, rayTMin, rayTMax,
                             texSize, rayDirUV,
                             hitT, hitBary, hitGeoNormal);
}

//=============================================================================
// Main Intersection Shader
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

    // Create bounding prism and intersect
    float dispScale = getDisplacementScale(matIdx);
    Prism fullPrism = makePrism(tri, 0.0, dispScale);

    float prismTEntry, prismTExit;
    if (!rayPrismIntersect(fullPrism, rayOrigin, rayDir, prismTEntry, prismTExit))
        return;

    prismTEntry = max(prismTEntry, rayTMin);
    prismTExit = min(prismTExit, rayTMax);
    if (prismTEntry >= prismTExit) return;

    // Project to UV space (Algorithm 1, line 3)
    float3 Q_entry = rayOrigin + prismTEntry * rayDir;
    float3 Q_exit = rayOrigin + prismTExit * rayDir;

    float2 baryEntry, baryExit;
    bool validEntry = inverseDisplacement(tri, Q_entry, baryEntry);
    bool validExit = inverseDisplacement(tri, Q_exit, baryExit);

    float2 triUVMin = min(min(tri.t0, tri.t1), tri.t2);
    float2 triUVMax = max(max(tri.t0, tri.t1), tri.t2);

    float2 initialUVMin = triUVMin;
    float2 initialUVMax = triUVMax;

    if (validEntry && validExit)
    {
        float2 uvEntry = baryToTex(tri, baryEntry);
        float2 uvExit = baryToTex(tri, baryExit);

        initialUVMin = min(uvEntry, uvExit);
        initialUVMax = max(uvEntry, uvExit);

        float2 uvPadding = (initialUVMax - initialUVMin) * 0.1 + float2(0.01, 0.01);
        initialUVMin = max(triUVMin, initialUVMin - uvPadding);
        initialUVMax = min(triUVMax, initialUVMax + uvPadding);
    }

    // Stack-based hierarchical traversal
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
            float hitT;
            float2 hitBary;
            float3 hitGeoNormal;

            if (testLeafRegion(tri, matIdx, rayOrigin, rayDir,
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

        // Get displacement bounds (TODO: use RMIP)
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

        // Bound reduction with validation
        float3 Q_entry = rayOrigin + rayDir * regionTEntry;
        float3 Q_exit = rayOrigin + rayDir * regionTExit;

        float2 projEntryBary, projExitBary;
        bool entryValid = inverseDisplacement(tri, Q_entry, projEntryBary);
        bool exitValid = inverseDisplacement(tri, Q_exit, projExitBary);

        if (entryValid)
        {
            float3 P_entry = getP(tri, projEntryBary);
            float3 N_entry = normalize(getN(tri, projEntryBary));
            float t_entry = dot(Q_entry - P_entry, N_entry);
            if (t_entry < hMin - 0.2 || t_entry > hMax + 0.2)
                entryValid = false;
        }

        if (exitValid)
        {
            float3 P_exit = getP(tri, projExitBary);
            float3 N_exit = normalize(getN(tri, projExitBary));
            float t_exit = dot(Q_exit - P_exit, N_exit);
            if (t_exit < hMin - 0.2 || t_exit > hMax + 0.2)
                exitValid = false;
        }

        if (entryValid && exitValid)
        {
            float2 projEntryUV = baryToTex(tri, projEntryBary);
            float2 projExitUV = baryToTex(tri, projExitBary);
            float2 projUVMin = min(projEntryUV, projExitUV);
            float2 projUVMax = max(projEntryUV, projExitUV);

            float2 padding = (bound.uvMax - bound.uvMin) * 0.05;
            projUVMin -= padding;
            projUVMax += padding;

            bound.uvMin = max(bound.uvMin, projUVMin);
            bound.uvMax = min(bound.uvMax, projUVMax);
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

    // Report hit
    if (foundHit && bestT >= rayTMin && bestT <= rayTMax)
    {
        float2 hitTexUV = baryToTex(tri, bestBary);

        DisplacementHitAttributes attr;
        attr.data.x = asfloat(packUV(hitTexUV));
        attr.data.y = asfloat(packNormal(bestGeoNormal));

        ReportHit(bestT, 0, attr.data);
    }
}
