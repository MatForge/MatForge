# RMIP Texel Marching Implementation Log

## Overview

This document tracks the implementation of the RMIP paper's texel marching algorithm.

**Paper**: "Displacement ray-tracing via inversion and oblong bounding" (SIGGRAPH Asia 2023)
**Reference**: [doc/papers/rmip.md](../../doc/papers/rmip.md)

---

## Key Concepts from Paper

### Algorithm 1 (Main Traversal)

1. Intersect ray with bounding prism
2. Project intersection points to texture space (inverse displacement)
3. Split at turning points (where ∂ψ/∂u = 0 or ∂ψ/∂v = 0)
4. Push 2D bounds to stack
5. Loop:
   - Pop bound from stack
   - If bound < marching_scale: do texel marching
   - Else: query RMIP for displacement bounds, compute 3D box, intersect ray
   - If hit: project intersection back to 2D, subdivide, push to stack

### Key Equations

- **Eq 1**: S(u,v) = P(u,v) + h(u,v) * N(u,v)/||N(u,v)|| (displaced surface)
- **Eq 2**: (P(u,v) - Q) × N(u,v) = 0 (displacement inversion - find uv for 3D point Q)
- **Eq 3**: ψ(u,v) = det(P-O, N, D) = (P-O)·(N×D) = 0 (implicit ray projection in texture space)
- **Eq 4**: ψu, ψv partial derivatives for finding turning points

### Texel Marching (Section 4.4)

- When 2D bounds are small enough, march through texels
- Use sign of ψ at texel corners to determine exit edge
- Test displaced surface at each texel

---

## Implementation Attempts

### Version 1: Texture-Space Texel Marching (Nov 29, 2025)

**Changes from brute force**:

1. Project ray entry/exit points to TEXTURE space via inverse displacement (Eq 2)
2. Compute bounding box in texture space (not barycentric)
3. Iterate through texels in texture space
4. Use ψ function (Eq 3) to filter which texels the ray passes through
5. Convert texel corners from texture space to barycentric for intersection test

**Key algorithm from paper (Section 4.4)**:

- The implicit form ψ(u,v) = det(P-O, N, D) = 0 defines the ray projection in texture space
- A texel contains part of the ray if ψ changes sign across its corners
- March through texels that have ψ sign changes

**Implementation details** (shaders/displacement_intersection.slang lines 725-880):

```
1. Project entry/exit 3D points via inverse displacement → barycentric → texture coords
2. Compute texture-space bounding box with margin
3. For each texel in bounding box:
   a. Convert texel corners (t00, t10, t01, t11) to texture coords
   b. Convert texture coords to barycentric via texToBary()
   c. Compute ψ at each corner
   d. If ψ changes sign (minPsi ≤ 0 and maxPsi ≥ 0) → ray passes through texel
   e. Also test texels with small |ψ| for safety
   f. Clamp barycentric coords to valid triangle domain
   g. Test two micro-triangles for intersection
```

**Key differences from brute force**:

- Brute force: Iterates through barycentric grid with triangular pattern
- Version 1: Iterates through texture-space texels with ψ filtering

**Potential issues**:

- texToBary() may fail for texels outside the triangle's UV mapping
- The ψ filtering threshold (0.1) may be too aggressive or too loose
- Texture wrapping/tiling not handled

**Testing Result**:

- ✅ Vertical view: looks correct
- ❌ Grazing angle: large curved gaps appearing
- ❌ More extreme grazing: most surface vanishes
- ❌ Extremely slow (even slower than brute force)

![V1 Vertical - OK](image/RMIP_texel_log/1764444934792.png)

![V1 Grazing - HOLES](image/RMIP_texel_log/1764444892855.png)

![V1 Extreme grazing - MOSTLY GONE](image/RMIP_texel_log/1764444962038.png)

**Analysis**: The problem is that at grazing angles, the ray's projection in texture space is a CURVED PATH that extends far beyond the bounding box computed from just entry/exit points. The paper (Section 4.2) mentions "turning points" where ψu=0 or ψv=0 - these are where the curve changes direction. My simple entry/exit bounding box misses these curves entirely.

---

### Version 2: Full Triangle UV Footprint (Nov 29, 2025)

**Fix for Version 1 issues**:

1. Use triangle's full texture footprint (t0, t1, t2) instead of ray projection
2. Remove ψ filtering entirely - just filter by valid barycentric coords
3. This is essentially brute force but in texture space instead of barycentric space

**Implementation details** (shaders/displacement_intersection.slang lines 725-838):

```
1. Compute triangle's texture-space bounding box from vertex UVs (t0, t1, t2)
2. For each texel in that bounding box:
   a. Convert texel corners to barycentric via texToBary()
   b. Check if any corner is inside valid triangle domain
   c. Skip texels entirely outside triangle
   d. Clamp barycentric coords and test micro-triangles
```

**Key differences from Version 1**:

- Version 1: Used ray projection bounds (too narrow at grazing angles)
- Version 2: Uses full triangle UV bounds (conservative, like brute force)

**Potential issues**:

- Will be similar performance to brute force (no culling)
- Still need to add hierarchical traversal for actual speedup

**Testing Result**:

- ✅ Visual correctness: No holes at grazing angles (tested with horizontal plane)
- ❌ **CATASTROPHICALLY SLOW**: 1 FPS / 1177ms per frame!
- ❌ So slow that vertical plane is unusable (can't rotate camera)

![V2 Vertical - OK but slow](image/RMIP_texel_log/1764446455261.png)

![V2 Horizontal at grazing - 1 FPS!](image/RMIP_texel_log/1764446711588.png)

**Root Cause Analysis**:

The problem is **iteration count explosion**:

| Method      | Iteration Space                    | Count for 512x512 texture |
| ----------- | ---------------------------------- | ------------------------- |
| Brute Force | Barycentric grid 64×64 triangular | ~2,048 cells              |
| Version 2   | Texture space 512×512             | **262,144 texels**  |

That's **128× more iterations** than brute force!

Even though we skip texels outside the triangle domain, we still have to:

1. Convert every texel to barycentric coords (expensive)
2. Check if it's valid (4 checks per texel)
3. Most texels are rejected, but we still pay the cost

**Key Insight**: The paper's "texel marching" is meant to be used **only at the leaf level** of hierarchical traversal, when the region is already narrowed down to a few texels. It's NOT meant to replace the entire traversal.

**Correct approach from paper**:

1. Start with coarse hierarchical traversal (using RMIP for bounds)
2. Subdivide regions that might contain the ray
3. Only switch to texel marching when region is small (~4×4 texels)

---

### Version 3: Barycentric Triangular Tessellation (Nov 29, 2025)

**Fix for Version 2 performance issues**:

- Go back to barycentric-space iteration (like brute force)
- Use triangular tessellation pattern that naturally fits the u+v≤1 constraint
- ~2,048 cells for 64×64 resolution vs 262,144 texels in V2

**Implementation details** (shaders/displacement_intersection.slang lines 725-816):

```
1. Compute resolution based on texture size: min(64, max(8, texSize/8))
2. For each row iu in [0, resolution):
   a. Compute u0, u1 for this row
   b. maxIv = resolution - iu  // KEY: triangular pattern!
   c. For each cell iv in [0, maxIv):
      - Compute b00, b10, b01, b11 corners
      - Clamp corners to u+v≤1 boundary
      - Test Triangle 1: b00, b10, b01
      - Test Triangle 2: b10, b11, b01 (if b11 valid)
```

**Key differences from V1/V2**:

- V1: Texture-space with ray projection bounds (wrong at grazing angles)
- V2: Texture-space with full UV footprint (correct but 128× slower)
- V3: Barycentric-space with triangular pattern (correct and fast)

**This is essentially the same as brute force** but kept in main shader file.
The paper's texel marching should only be used at leaf level of hierarchical traversal.

**Testing Result**:

- ✅ Visual correctness: No holes at any angle
- ✅ Performance: 7 FPS / 140ms (same as brute force)
- ❌ **REJECTED**: User says this is just brute force with different code organization
- ❌ Does NOT use the RMIP data structure at all!

**User Feedback**: "yes this is the same as bf but that's not what we want. we want to properly implement the paper with full use of the rmip data structure not another brute force method."

![1764447714181](image/RMIP_texel_log/1764447714181.png)

---

### Version 4: Proper RMIP Hierarchical Traversal (Nov 29, 2025)

**Goal**: Implement Algorithm 1 from the paper with proper RMIP usage

**Key Algorithm (from paper Section 4 & Algorithm 1)**:

```
1: function IntersectRMIP(ray, triangle, prism, rmip)
2:   points = sort(intersect(ray, prism))
3:   bounds = inverse_displacement(points, triangle)  ← Section 4.1
4:   turning_points = zero_uv_derivative(ray, triangle)  ← Section 4.2
5:   bounds = split(bounds, turning_points)  ← Section 4.2
6:   while bounds is not empty do  ← Stack of 2D ray bounds
7:     bound = bounds.pop()
8:     if bound is smaller than marching_scale then
9:       for texel in texel_marching(bound) do  ← Section 4.4
10:        if hit = displaced_surface_intersect(ray, texel) then
11:          return hit  ← Front-to-back traversal, terminate on first hit
12:    box = surface_bounds(triangle, bound, rmip)  ← Section 5
13:    if not hits = intersect(ray, box) then
14:      continue
15:    bound = reduce(bound, hits)  ← Section 4.3
16:    for front, back in split(bound) do  ← Section 4.3
17:      bounds.push(back, front)  ← Back first so front is popped earlier
```

**Key Differences from V1-V3**:

1. **Stack-based traversal**: Push/pop 2D bounds, front-to-back ordering
2. **RMIP queries**: Use RMIP structure for rectangular min/max displacement queries
3. **2D-3D ping-pong**: Project 3D intersection back to 2D to reduce bounds
4. **Bound subdivision**: Split 2D bound directly in texture space (not 3D midpoint)
5. **Texel marching at leaf**: Only when bound < marching_scale (~4 texels)
6. **ψ-based texel marching**: Use ψ sign at corners to determine exit edge

**Implementation Plan**:

1. Convert barycentric bounds to texture-space bounds for RMIP queries
2. Query RMIP for displacement min/max over rectangular regions
3. Compute 3D AABB using displacement bounds
4. Ray-AABB intersection with entry/exit points
5. Project entry/exit back to 2D via inverse displacement
6. Split 2D bound at midline (longer dimension)
7. Push children to stack (back first, so front pops first)
8. Texel marching with ψ sign when bound is small

**Potential Challenges**:

- Need proper RMIP sampling function (currently just samples 4 corners)
- Texture-space vs barycentric-space coordinate conversions
- Handling the triangular domain constraint (u + v ≤ 1) with rectangular bounds
- Finding turning points (ψu=0, ψv=0)

**Testing Result**:

- ❌ **THIN EDGES ONLY**: Only thin edges of displaced surface rendered
- ✅ Performance: Very fast (hierarchical culling working)
- ✅ Edge shapes are correct (displaced correctly)

![V4 - Thin edges only](image/RMIP_texel_log/1764448237259.png)

![V4 - Another angle](image/RMIP_texel_log/1764448270854.png)

![V4 - Third view](image/RMIP_texel_log/1764448309105.png)

**Root Cause Analysis**:
The **bound reduction step** (line 15 in Algorithm 1) is too aggressive. The issue is:

1. We project 3D ray-box intersection points back to 2D via inverse displacement
2. These projections give only **points on the ray's projection curve**
3. But the ray's projection in 2D is a **curve**, not just entry/exit points
4. The curve can extend well beyond the entry/exit projections
5. By using `max(bound.baryMin, projected_min)` we're cutting off parts of the curve

**Paper insight (Section 4.3, Figure 5)**:

- "Bound tightening via interval projection is beneficial only for some rays"
- The paper uses **direct 2D subdivision** as the primary method
- Bound reduction is optional and can be skipped

**Fix**: Remove aggressive bound reduction, rely on subdivision only.

---

### Version 4.1: Fix Bound Reduction (Nov 29, 2025)

**Changes from V4**:

1. Remove aggressive bound reduction that clips the ray curve
2. Keep subdivision as the primary bound-shrinking method
3. Only update tMin/tMax from ray-box intersection (safe)

**Testing Result**:

- ❌ Planes: Same as V4 (thin edges only)
- ❌ Chipped planks: Worse than V4 (barely visible edges)
- ⚠️ Cubes: Better than planes, more surface visible but still incorrect

![V4.1 - Plane still thin edges](image/RMIP_texel_log/1764448625173.png)

![V4.1 - Chipped planks worse](image/RMIP_texel_log/1764448734936.png)

![V4.1 - Cube better but incorrect](image/RMIP_texel_log/1764448837394.png)

**Root Cause Analysis**:
The texture bounds calculation is **WRONG**! The code assumes barycentric-to-texture mapping is axis-aligned:

```slang
float2 texMin = baryToTex(tri, bound.baryMin);
float2 texMax = baryToTex(tri, bound.baryMax);
float2 texBoundsSize = abs(texMax - texMin) * float2(texSize);
```

But `baryToTex` is a LINEAR transformation: `tex = t0 + u*dTdu + v*dTdv`

For barycentric region `[uMin,uMax] × [vMin,vMax]`, the 4 corners in texture space are:

1. `t0 + uMin*dTdu + vMin*dTdv` (baryMin)
2. `t0 + uMax*dTdu + vMin*dTdv` ← MISSING!
3. `t0 + uMin*dTdu + vMax*dTdv` ← MISSING!
4. `t0 + uMax*dTdu + vMax*dTdv` (baryMax)

The actual texture bounding box is the min/max of ALL 4 corners!

**Why cubes work better**: Different cube faces have different UV mappings. Some might accidentally be axis-aligned with the barycentric coordinates.

**Fix**: Compute proper texture bounding box using all 4 corners of the barycentric region.

---

### Version 4.2: Fix Texture Bounds Calculation (Nov 29, 2025)

**Changes from V4.1**:

1. Compute all 4 corners of barycentric region in texture space
2. Take min/max of all 4 corners for proper texture bounding box
3. Use correct bounds for both size check and RMIP queries

**Testing Result**:

- ❌ Same "thin edges only" as V4.1
- No improvement from texture bounds fix

**Root Cause Analysis** (after deeper investigation):

The **fundamental issue** was discovered: `getDisplacementBounds()` was NOT using the RMIP data structure at all! It was sampling the displacement map directly with a 5×5 grid:

```slang
// BAD: Only 25 samples - can miss local min/max!
for (int i = 0; i <= samples; i++)
    for (int j = 0; j <= samples; j++)
        sample and track min/max
```

This causes:

1. Bounds that are TOO TIGHT (miss actual min/max between sample points)
2. Ray-AABB test fails when AABB is smaller than it should be
3. Regions get incorrectly culled → only "thin edges" visible

The brute force version works because it uses the GLOBAL bounds (0 to DISPLACEMENT_SCALE) for everything, which is always correct but provides no culling benefit.

---

### Version 5: Proper RMIP Queries (Nov 29, 2025)

**Root Cause Fix**:
The shader was missing RMIP texture bindings entirely! Fixed by:

1. Added RMIP texture bindings:

```slang
[[vk::binding(8, 1)]] Texture2DArray<float2> rmipMaps[8];
[[vk::binding(10, 1)]] SamplerState rmipSampler;
```

2. Replaced sampling-based `getDisplacementBounds()` with `queryRMIPFull()`:

```slang
float2 bounds = queryRMIPFull(rmipMaps[matIdx], rmipSampler, texMin, texMax, maxLevel);
hMin = bounds.x * DISPLACEMENT_SCALE;
hMax = bounds.y * DISPLACEMENT_SCALE;
```

**Key Insight**: The RMIP data structure was being built by `RmipBuilder::buildRMIP()` and bound to descriptor set at binding 8, but the intersection shader never used it! The `queryRMIPFull()` function in `rmip_common.h.slang` implements the proper 4-rectangle decomposition for O(1) min/max queries.

**Testing Result**:

- ❌ Simple planes: Nothing rendered at all angles
- ❌ Chipped planks: Very thin edge at certain angles only
- ❌ Cube checker: Two layers of checker pattern
- ❌ Cube gradient: Single square frame
- ❌ Spheres: Strange patterns inside bounding box

![1764451605678](image/RMIP_texel_log/1764451605678.png)

![1764451638537](image/RMIP_texel_log/1764451638537.png)

![1764451660153](image/RMIP_texel_log/1764451660153.png)

![1764451617577](image/RMIP_texel_log/1764451617577.png)

![1764451691784](image/RMIP_texel_log/1764451691784.png)

![1764451712851](image/RMIP_texel_log/1764451712851.png)

![1764451747554](image/RMIP_texel_log/1764451747554.png)

**Root Cause**: Layer indexing mismatch between build and query!

---

### Version 5.1: Fix RMIP Layer Indexing (Nov 29, 2025)

**Critical Bug Found**: Two different layer indexing functions gave DIFFERENT results:

```slang
// Used in BUILD shaders (rmip_init.compute.slang, rmip_expand.compute.slang):
computeLayerIndex(p, q, stride) = p + q * stride

// Used in QUERY function (queryRMIPFull):
getRmipLayer(p, q, maxLevel) = p * (maxLevel + 1) + q  // WRONG!
```

For example, with maxLevel=9 (512×512 texture):

- `computeLayerIndex(2, 3, 10)` = 2 + 3×10 = **32**
- `getRmipLayer(2, 3, 9)` = 2×10 + 3 = **23**

The query was reading from the WRONG layer, giving garbage min/max values!

**Fix**: Changed `getRmipLayer()` to match `computeLayerIndex()`:

```slang
uint getRmipLayer(uint p, uint q, uint maxLevel)
{
    uint stride = maxLevel + 1;
    return p + q * stride;  // Now matches computeLayerIndex(p, q, stride)
}
```

**Testing Result**:

- ❌ Exactly same results as V5 - no improvement
- Layer indexing fix was necessary but not sufficient

**Analysis**: The RMIP query is still returning wrong values. Other potential issues:

1. RMIP texture might not be bound correctly
2. Sampler might use linear filtering instead of point
3. UV coordinates in query might be wrong
4. RMIP texture might not be built correctly

---

### Version 5.2: Conservative Bounds Test (Nov 29, 2025)

**Goal**: Verify the hierarchical traversal logic works independently of RMIP.

**Change**: Use conservative global bounds like brute force:

```slang
void getDisplacementBounds(...)
{
    hMin = 0.0;
    hMax = DISPLACEMENT_SCALE;
}
```

This provides NO culling benefit but should be CORRECT. If V5.2 works, the traversal logic is correct and the issue is purely in the RMIP query mechanism.

**Testing Result**:

- ❌ Planes: Similar to V4 - only thin edges at certain angles
- ❌ 3D scenes: Completely messed up (worse than V5.1)
- ❌ **CONCLUSION**: Hierarchical traversal logic itself is broken!

![1764452441584](image/RMIP_texel_log/1764452441584.png)

![1764452455950](image/RMIP_texel_log/1764452455950.png)

![1764452493974](image/RMIP_texel_log/1764452493974.png)

![1764452528177](image/RMIP_texel_log/1764452528177.png)

**Analysis**: Even with conservative bounds (0, DISPLACEMENT_SCALE), V5.2 fails. The problem is NOT in RMIP queries - it's in the hierarchical traversal algorithm itself. The `computeRegionAABB()` function or the subdivision logic is culling valid regions.

---

### Version 5.3: Direct Brute Force Tessellation (Nov 29, 2025)

**Goal**: Bypass hierarchical traversal entirely and verify basic tessellation works.

**Approach**: Replace the entire hierarchical traversal with direct brute force tessellation (same as bf.slang):

- Simple AABB from triangle vertices
- Triangular tessellation pattern (u + v <= 1)
- 64×64 resolution like brute force
- No stack-based traversal, no RMIP queries

If V5.3 works, the basic tessellation is correct and we need to fix the hierarchical traversal from scratch.

**Testing Result**:

- ✅ **WORKS CORRECTLY** - Identical to brute force reference
- ✅ All models render correctly (planes, cubes, spheres)
- ✅ Performance: Same as brute force (~7 FPS / 140ms)

![1764452984237](image/RMIP_texel_log/1764452984237.png)

![1764453014008](image/RMIP_texel_log/1764453014008.png)

**Conclusion**: V5.3 proves that:

1. The micro-triangle intersection logic (`intersectMicroTriangle`) is CORRECT
2. The simple AABB computation from triangle vertices is CORRECT
3. The triangular tessellation pattern is CORRECT
4. The problem is ENTIRELY in the hierarchical traversal logic (V4-V5.2)

**Root Cause Analysis of V4-V5.2 Failures**:

Looking at the paper's Algorithm 1 more carefully:

- The paper works in **TEXTURE SPACE** (UV), not barycentric space
- The paper's "2D bounds" are axis-aligned rectangles in UV space
- RMIP queries are over rectangular UV regions
- The paper projects 3D ray-box intersection points back to 2D UV via inverse displacement

Our V4-V5.2 implementations had a fundamental flaw:

- We tracked bounds in **BARYCENTRIC SPACE**
- The valid barycentric domain is a **TRIANGLE** (u+v≤1), NOT a rectangle
- `computeRegionAABB()` sampled corners of a rectangular barycentric region
- When corners fell outside u+v≤1, they were skipped or clamped incorrectly
- This led to incorrect/degenerate AABBs that caused false negative culling

**The Fix (V6)**:

1. Track bounds in **TEXTURE SPACE**, not barycentric space
2. Start with triangle's texture footprint (bounding box of t0, t1, t2)
3. Subdivide in texture space
4. Convert texture coords to barycentric only for 3D position computation
5. Check if texture region overlaps valid triangle domain in barycentric space

---

### Version 6: Proper Texture-Space Hierarchical Traversal (Nov 29, 2025)

**Goal**: Implement the paper's Algorithm 1 correctly by working in texture space.

**Key Changes from V5.2**:

1. Track 2D bounds in **texture space** (UV), not barycentric space
2. Use proper texture-to-barycentric conversion for overlap checks
3. Compute 3D AABB by sampling the texture region properly
4. Subdivide in texture space (split longer UV dimension)
5. Query RMIP with texture-space rectangles directly

**Implementation Details** (displacement_intersection.slang lines 664-1129):

1. **`UVBound` struct**: Stores UV min/max for texture-space regions
2. **`uvRegionOverlapsTriangle()`**: Checks if UV rectangle overlaps valid triangle domain
   - Converts UV corners to barycentric
   - Checks if any corner is inside u+v≤1
   - Also checks if triangle vertices are inside UV region
   - Checks edge-rectangle intersections for robustness
3. **`computeUVRegionAABB()`**: Computes 3D AABB for UV region
   - Samples 5×5 grid within UV region
   - Converts each UV to barycentric, skips if outside triangle
   - Also samples triangle vertices if they fall within UV region
4. **`tessellateUVRegion()`**: Tessellates small UV regions
   - Works in UV space, converts to barycentric for intersection
   - Uses clampBary() to handle edge cases
5. **Main traversal loop**:
   - Stack-based with UV bounds (MAX_STACK_SIZE = 32)
   - Subdivides along longer UV dimension
   - Uses MARCHING_SCALE = 8 texels as threshold
   - Still uses conservative bounds (0, DISPLACEMENT_SCALE) for testing

**Testing Result**: Partial success with issues at grazing angles

- Horizontal plane: Vertical view correct but slow; tearing at grazing angles
- Vertical plane: Vertical strips of lighter color visible even at normal angles
- Chipped planks: Most resistant to tearing, occurs only at extreme angles
- 3D cubes: Fail completely - two layers of strange pattern with tearing

**Root Cause Analysis**:
The `computeUVRegionAABB()` function creates a fallback AABB when no grid samples are valid.
When a UV region doesn't meaningfully overlap the triangle (no grid points inside triangle),
it creates an AABB at the triangle center which is completely wrong for that UV region.
This causes false negative culling → tearing artifacts.

![1764454654753](image/RMIP_texel_log/1764454654753.png)

![1764454677628](image/RMIP_texel_log/1764454677628.png)

![1764454693725](image/RMIP_texel_log/1764454693725.png)

![1764454751130](image/RMIP_texel_log/1764454751130.png)

![1764454800541](image/RMIP_texel_log/1764454800541.png)

![1764454829667](image/RMIP_texel_log/1764454829667.png)

![1764454875156](image/RMIP_texel_log/1764454875156.png)

![1764454912275](image/RMIP_texel_log/1764454912275.png)

![1764454936094](image/RMIP_texel_log/1764454936094.png)

![1764454966428](image/RMIP_texel_log/1764454966428.png)

![1764454999604](image/RMIP_texel_log/1764454999604.png)

---

### Version 6.1: Fix Tearing at Grazing Angles (Nov 29, 2025)

**Archive**: `displacement_intersection_v6.1.slang` (after testing)

**Problem**: V6 had tearing artifacts because `computeUVRegionAABB()` created a fallback AABB
at the triangle center when no grid samples were valid. This fallback was completely wrong
for UV regions that don't meaningfully overlap the triangle.

**Fix**:

1. Changed `computeUVRegionAABB()` to return `bool` instead of `void`
2. Returns `false` if no valid samples found (instead of creating fallback AABB)
3. Increased grid sampling from 5×5 to 8×8 for better coverage
4. Added `addSampleToAABB()` helper function for cleaner code
5. Added sampling of triangle edge intersections with UV rectangle edges
6. Updated both call sites to handle boolean return:
   - First call (full triangle AABB): Returns early if false (should never happen)
   - Second call (traversal loop): `continue` if false (skip region entirely)

**Key Code Changes**:

```slang
// Before (V6):
void computeUVRegionAABB(...)
{
    // ... sampling ...
    if (validSamples == 0)
    {
        // WRONG: Create fallback AABB at triangle center
        float2 centerBary = float2(0.333, 0.333);
        // ...
    }
}

// After (V6.1):
bool computeUVRegionAABB(...)
{
    // ... sampling with 8×8 grid + edge intersections ...
    if (validSamples == 0)
        return false;  // Skip this region entirely
    return true;
}

// In traversal loop:
if (!computeUVRegionAABB(tri, bound.uvMin, bound.uvMax, hMin, hMax, aabbMin, aabbMax))
    continue;  // UV region doesn't meaningfully overlap triangle
```

**Testing Result**: Tearing slightly smaller but same pattern persists. FPS slower than V6.

**Conclusion**: The grid sampling approach is not the root cause. The problem is more fundamental.

---

### Comparison: V6.1 vs Paper's Algorithm 1

**Paper's Algorithm 1 (Lines 296-317 of rmip.md)**:

| Step                      | Paper                                                                            | V6.1                                  | Status                          |
| ------------------------- | -------------------------------------------------------------------------------- | ------------------------------------- | ------------------------------- |
| 1. Initialize             | Intersect ray with prism,**project to 2D via inverse displacement (Eq 2)** | Start with triangle's UV bounding box | ❌ Missing                      |
| 2. Turning points         | Find where ∂ψ/∂u = 0 or ∂ψ/∂v = 0 (Eq 4), split bounds                     | None                                  | ❌ Missing                      |
| 3. Surface bounds         | Query RMIP + affine arithmetic                                                   | Query RMIP + grid sampling            | ⚠️ Different                  |
| 4. Ray-box test           | Intersect ray with 3D box                                                        | Intersect ray with 3D AABB            | ✅ Same                         |
| 5.**Reduce bounds** | **Project ray-box hits back to 2D UV**                                     | None                                  | ❌**MISSING KEY FEATURE** |
| 6. Subdivide              | Split 2D bound in middle                                                         | Split along longer UV dimension       | ✅ Similar                      |
| 7. Texel march            | March through texels using ψ sign                                               | Tessellate UV region                  | ⚠️ Different                  |

**Key Missing Features in V6.1**:

1. **Inverse Displacement Mapping (Eq 2)**: `(P(u,v) - Q) × N(u,v) = 0`

   - Paper's CORE innovation: project 3D points to 2D UV space
   - Used to initialize bounds from ray-prism intersection
   - **Used to REDUCE bounds after ray-box intersection** (the "ping-pong")
   - This is what makes the paper's method converge efficiently
2. **Implicit Ray Projection (Eq 3)**: `ψ(u,v) = det(P-O, N, D) = 0`

   - Defines the ray's projection as a curve in texture space
   - Used to find turning points (∂ψ/∂u = 0, ∂ψ/∂v = 0)
   - Used for texel marching (sign of ψ at corners determines exit edge)
3. **Bound Reduction (Line 15)**: `bound = reduce(bound, hits)`

   - After ray-box intersection yields [tEntry, tExit]
   - Project tEntry point and tExit point back to 2D UV via inverse displacement
   - This TIGHTENS the 2D bound based on actual ray intersection
   - This is the "ping-pong" between 2D and 3D that makes it work!

**Why V6.1 Fails**:

- We never tighten bounds based on ray-box intersection
- We just subdivide blindly in half
- The paper projects ray-box hits back to 2D, which can dramatically tighten bounds
- Without this, we waste iterations on regions the ray doesn't actually pass through

**The Fix (V7)**: Implement inverse displacement mapping (Eq 2) for:

1. Projecting 3D points to 2D UV coordinates
2. Reducing 2D bounds after ray-box intersection
3. Proper initialization from ray-prism intersection

![1764455819516](image/RMIP_texel_log/1764455819516.png)

---

### Version 7: Bound Reduction via Inverse Displacement (Nov 29, 2025)

**Goal**: Implement the paper's key "ping-pong" feature - project ray-AABB intersection back to 2D UV to tighten bounds.

**Key Change**: After ray-AABB intersection yields [tEntry, tExit]:

1. Compute 3D points: `Q_entry = O + tEntry*D`, `Q_exit = O + tExit*D`
2. Project these back to 2D UV using inverse displacement (Eq 2)
3. Use the projected UV points to TIGHTEN the current bounds
4. This is "reduce" step in Algorithm 1, line 15

**Code Added** (lines 1153-1187):

```slang
// V7: Bound reduction via inverse displacement (Paper's line 15)
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

    // Compute new tighter UV bounds
    float2 projUVMin = min(uvEntry, uvExit);
    float2 projUVMax = max(uvEntry, uvExit);

    // Intersect with current bounds (can only shrink, never expand)
    bound.uvMin = max(bound.uvMin, projUVMin);
    bound.uvMax = min(bound.uvMax, projUVMax);
}
```

**Why This Should Help**:

- The paper says this is what makes their method efficient
- Without bound reduction, we subdivide blindly in half
- With bound reduction, we focus only on where the ray actually passes
- For rays nearly parallel to the surface, the 2D projection can be tiny
- This dramatically reduces the number of traversal iterations

**Testing Result**: Partial improvement but still has tearing issues

- At some non-vertical angles: Planes look correct ✅
- At vertical viewing: Small tearings near CENTER of four edges (moves with camera)
- At grazing angles: Very LARGE tearing that strips plane into two parts (moves with camera)

**Analysis**: The tearings MOVE with camera angle, suggesting the inverse displacement projection
is sometimes returning incorrect UV coordinates. The issue is:

1. **Missing Turning Points (Paper lines 4-5)**: The ray's 2D projection is a CURVE (quadric from Eq 3),
   NOT just two endpoints. The paper explicitly says to find "turning points" where ∂ψ/∂u = 0 or ∂ψ/∂v = 0,
   and SPLIT the bounds at these points.
2. **Why this matters**: Imagine a ray whose 2D projection looks like a "U" shape:

   - Entry and exit might be at similar UV coordinates
   - But the curve extends MUCH further in one direction
   - Without the turning point (bottom of U), our rectangle is too narrow
   - This causes false negative culling → tearing
3. **What V7 does wrong**: We only project entry/exit points and make a rectangle.
   This ONLY works if the projection curve is monotonic in both u and v.
   When the ray passes through a turning point, the rectangle doesn't bound the curve!

**The Fix (V8)**: Implement turning point detection from paper's lines 4-5:

- Find where ψ_u = 0 (line in UV space)
- Find where ψ_v = 0 (line in UV space)
- These lines intersect the projected ray curve at turning points
- Include these turning points when computing the UV rectangle

![1764456247141](image/RMIP_texel_log/1764456247141.png)

![1764456293309](image/RMIP_texel_log/1764456293309.png)

![1764456321514](image/RMIP_texel_log/1764456321514.png)

![1764456354695](image/RMIP_texel_log/1764456354695.png)

![1764456372081](image/RMIP_texel_log/1764456372081.png)

![1764456383221](image/RMIP_texel_log/1764456383221.png)

![1764456392766](image/RMIP_texel_log/1764456392766.png)

![1764456475235](image/RMIP_texel_log/1764456475235.png)

---

### Version 8: Turning Point Detection (Nov 29, 2025)

**Archive**: `displacement_intersection_v7.slang` (archived before implementing V8)

**Goal**: Fix V7's tearing by implementing turning point detection from paper's lines 4-5.

**Problem Analysis (from V7)**:

- V7 only uses entry/exit points to compute UV bounds
- But the ray's 2D projection is a CURVE (quadric from Eq 3), not just two points
- When the curve "bends" (has extrema), entry/exit bounds miss the extent
- Paper explicitly says to find turning points where ∂ψ/∂u = 0 or ∂ψ/∂v = 0

**Key Insight**:

- ψ(u,v) = det(P-O, N, D) is a QUADRIC in (u,v) (bilinear interpolation of P and N)
- ψ_u and ψ_v are LINEAR functions (gradient of bilinear = linear)
- ψ_u = 0 defines a LINE in barycentric space
- ψ_v = 0 defines another LINE in barycentric space
- These lines intersect the ray curve at its turning points!

**Implementation** (shaders/displacement_intersection.slang):

1. **New function `findTurningPointsInRegion()`** (lines 288-363):

   - Computes ψ_u and ψ_v at three reference points: (0,0), (1,0), (0,1)
   - Derives linear coefficients: `ψ_u(u,v) = a_u + b_u*u + c_u*v`
   - Finds where ψ_u = 0 line intersects rectangle edges (left, right, bottom, top)
   - Same for ψ_v = 0 line
   - Returns up to 4 candidate turning points
2. **Updated V8 bound reduction** (lines 1232-1307):

   ```slang
   // Find turning points in barycentric region around entry/exit
   float2 turningPts[4];
   int numTurning;
   findTurningPointsInRegion(tri, baryMin, baryMax, rayOrigin, rayDir, turningPts, numTurning);

   // Include turning points that are actually on the ray curve (ψ ≈ 0)
   for (int tp = 0; tp < numTurning; tp++)
   {
       float psiVal = psi(tri, turningPts[tp], rayOrigin, rayDir);
       if (abs(psiVal) < 0.1 && baryInTriangle(turningPts[tp], 0.02))
       {
           float2 tpUV = baryToTex(tri, turningPts[tp]);
           projUVMin = min(projUVMin, tpUV);
           projUVMax = max(projUVMax, tpUV);
       }
   }
   ```
3. **Safety checks**:

   - Only apply bound reduction if entry AND exit are within current bounds
   - This prevents bad inverse displacement results from propagating
   - Added padding for numerical robustness

**Build Status**: ✅ Compiled successfully

**Testing Result**: Tearing still present but MUCH SMALLER than V7

- Same pattern of tearing as V7 (center of edges, grazing angles)
- Tearing size is significantly reduced compared to V7
- Still camera-dependent (moves with viewing angle)

![1764457409175](image/RMIP_texel_log/1764457409175.png)

![1764457426778](image/RMIP_texel_log/1764457426778.png)

![1764457450417](image/RMIP_texel_log/1764457450417.png)

![1764457510310](image/RMIP_texel_log/1764457510310.png)

![1764457523635](image/RMIP_texel_log/1764457523635.png)

---

### Comparison: V8 vs Paper's Algorithm 1

**Paper's Algorithm 1 (Lines 296-317 of rmip.md)**:

| Step                                    | Paper                                                                   | V8                                                             | Status                          |
| --------------------------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------- |
| **1. Bounding Volume**            | **PRISM** (triangular cross-section)                              | AABB (axis-aligned box)                                        | ❌**CRITICAL DIFFERENCE** |
| **2. Initialize**                 | Intersect ray with PRISM, project to 2D via inverse displacement (Eq 2) | Intersect ray with AABB, start with triangle's UV bbox         | ⚠️ Different                  |
| **3. Turning points (lines 4-5)** | Find turning points,**SPLIT initial bounds** at them              | Find turning points during bound reduction (not initial split) | ⚠️ Partial                    |
| **4. Surface bounds**             | Query RMIP +**affine arithmetic**                                 | Query RMIP +**grid sampling**                            | ⚠️ Different                  |
| **5. Ray-box test**               | Intersect ray with 3D box                                               | Intersect ray with 3D AABB                                     | ✅ Same                         |
| **6. Reduce bounds (line 15)**    | Project ray-box hits back to 2D UV                                      | Project ray-box hits back to 2D UV                             | ✅**Implemented in V7**   |
| **7. Include turning points**     | Include turning points in projected bounds                              | Include turning points in projected bounds                     | ✅**Implemented in V8**   |
| **8. Subdivide (line 16)**        | Split 2D bound in middle using ψ line intersection                     | Split along longer UV dimension                                | ⚠️ Different                  |
| **9. Texel march (lines 8-11)**   | March using**ψ sign at corners** to find exit edge               | Tessellate UV region (no ψ-based marching)                    | ⚠️ Different                  |
| **10. Termination**               | **Immediate return on first hit** (front-to-back)                 | Track best hit, continue searching                             | ✅ Similar                      |

**Key Remaining Differences**:

#### 1. **PRISM vs AABB** (Most Critical)

**Paper (Section 3 & Fig 2c)**:

> "Using bounding prisms provides a good compromise between intersection complexity and tightness... An even more important advantage of using prisms over axis-aligned 3D boxes is the **guarantee that every 3D location inside them can be successfully projected to texture space**."

**Why this matters**:

- A prism is defined by extruding the base triangle along displacement directions
- ALL points inside a prism are guaranteed to have valid inverse displacement (Fig 4)
- With AABB, some points may be outside the convergence region of inverse displacement
- This is why our inverse displacement sometimes returns bad results → tearing!

**Paper (Fig 4 caption)**:

> "Not all 3D points can be successfully projected; however, we only deal with points located inside a prism around the triangle, and **these are guaranteed to fall inside the triangle**."

#### 2. **Initial Bound Splitting at Turning Points**

**Paper (lines 4-5)**:

> "turning_points = zero_uv_derivative(ray, triangle)"
> "bounds = split(bounds, turning_points)"

**What paper does**:

- Find turning points ONCE at initialization
- Split the INITIAL bounds at these points
- Push multiple initial segments to the stack

**What V8 does**:

- Find turning points DURING bound reduction (at each iteration)
- Include them in bounds but don't split at them
- This may not properly handle curves that span turning points

#### 3. **Affine Arithmetic vs Grid Sampling**

**Paper (Section 3)**:

> "For the 2D→3D mapping, we employ **affine arithmetic** as Thonat et al. [2021]."

**What paper does**:

- Uses affine arithmetic to compute tight 3D bounds from 2D UV region
- Provides mathematically guaranteed bounds

**What V8 does**:

- Samples 8×8 grid + triangle vertices + edge intersections
- May miss extrema if they don't fall on sample points

#### 4. **Texel Marching with ψ Sign**

**Paper (Section 4.4 + inline figure)**:

> "The sign of the implicit form ψ (3) at each texel corner indicates from which edge the ray leaves the texel."

**What paper does**:

- March through texels one by one
- Use ψ sign at corners to determine exit edge (like DDA ray marching)
- Efficient front-to-back traversal

**What V8 does**:

- Tessellate the entire UV region
- Test all micro-triangles
- Less efficient, doesn't use ψ for traversal

**Conclusion**: The most likely cause of remaining tearing is the **PRISM vs AABB** difference.

---

### Version 9: Initial Turning Point Splitting (Nov 29, 2025)

**Archive**: `displacement_intersection_v8.slang` (archived before implementing V9)

**Goal**: Implement paper's lines 4-5 - split INITIAL bounds at turning points BEFORE the main loop.

**Problem Analysis (from V8)**:

- V8 finds turning points DURING bound reduction (at each iteration)
- But the paper finds them ONCE at initialization and SPLITS the initial bounds
- Each resulting segment should have monotonic ray projection
- V8's approach may not properly handle curves that span turning points in initial bounds

**Key Insight from Paper (lines 4-5)**:

```
turning_points = zero_uv_derivative(ray, triangle)
bounds = split(bounds, turning_points)
```

The paper:

1. Finds turning points for the ENTIRE triangle (not just current region)
2. Splits initial bounds at these points
3. Pushes MULTIPLE initial segments to the stack
4. Each segment is guaranteed to have monotonic ray projection

**Implementation** (shaders/displacement_intersection.slang):

1. **New function `findGlobalTurningPoints()`** (lines 1076-1200):

   - Finds where ψ_u = 0 and ψ_v = 0 lines intersect TRIANGLE EDGES (not rectangle)
   - Triangle edges: u=0, v=0, u+v=1
   - Only includes points that are ON the ray curve (|ψ| < 0.05)
   - Returns UV coordinates of turning points
2. **Initial bound splitting** (lines 1283-1372):

   ```slang
   // V9: Find global turning points and split initial bounds
   float2 turningUVs[4];
   int numTurning;
   findGlobalTurningPoints(tri, rayOrigin, rayDir, turningUVs, numTurning);

   if (numTurning == 0) {
       // No turning points - single initial bound
       stack[stackPtr++] = {triUVMin, triUVMax};
   } else {
       // Sort turning points by U coordinate
       // Split U range at turning point U values
       // Then split each segment by V if needed
       // Push multiple segments to stack
   }
   ```
3. **Splitting strategy**:

   - First split by U coordinate (creates vertical strips)
   - Then split each strip by V coordinate if a turning point falls within it
   - Results in segments where ray projection is monotonic in both U and V

**Build Status**: ✅ Compiled successfully

**Testing Result**: ❌ No visual difference from V8

- Same tearing pattern as V8 at grazing angles
- Initial turning point splitting did not help
- Conclusion: The fundamental issue is NOT turning point handling

**Analysis**: V9 proves that initial turning point splitting alone doesn't solve the tearing problem. The root cause must be one of the remaining differences between our implementation and the paper.

---

## Current Goals (V10+)

Based on the V8 vs Paper comparison, the three remaining key differences are:

### 1. **PRISM vs AABB** (Most Critical - V10 Target)

**Paper (Section 3 & Fig 2c, 4)**:

> "An even more important advantage of using prisms over axis-aligned 3D boxes is the **guarantee that every 3D location inside them can be successfully projected to texture space**."
> "The key advantage of using a prism as a 3D bounding primitive over a simple axis-aligned box is that it is fully contained inside the convergence region, providing the guarantee that all our projections will fall inside the base triangle."

**Current Implementation**: Uses AABB (axis-aligned bounding box)

- Some points in AABB may be outside the convergence region
- Inverse displacement can fail for these points
- This causes tearing at grazing angles

**Prism Structure**:

- 6 vertices: 3 bottom + 3 top
- Bottom: `P_i + h_min * N_i` for each vertex
- Top: `P_i + h_max * N_i` for each vertex
- 5 faces: 2 triangular caps + 3 quadrilateral sides
- ALL points inside guaranteed to have valid inverse displacement

### 2. **Affine Arithmetic** (Future)

**Paper (Section 3)**:

> "For the 2D→3D mapping, we employ **affine arithmetic** as Thonat et al. [2021]."

**Current Implementation**: Grid sampling (8×8 + vertices + edges)

- May miss extrema between sample points
- Not mathematically guaranteed bounds

### 3. **Texel Marching with ψ Sign** (Future)

**Paper (Section 4.4)**:

> "The sign of the implicit form ψ (3) at each texel corner indicates from which edge the ray leaves the texel."

**Current Implementation**: Tessellate entire UV region

- Less efficient than DDA-style marching
- Doesn't use ψ for traversal direction

---

### Version 10: Bounding Prism Implementation (Nov 29, 2025)

**Archive**: `displacement_intersection_v9.slang` (archived before implementing V10)

**Goal**: Replace AABB with bounding prism as the paper describes.

**Implementation Files**:

- `displacement_intersection_prism.slang` - Standalone prism implementation
- `displacement_intersection.slang` - Updated main shader with prism

**Key Implementation Details**:

1. **Prism Structure** (lines 145-160):

```slang
struct Prism
{
    // Bottom triangle (displaced by h_min)
    float3 b0, b1, b2;
    // Top triangle (displaced by h_max)
    float3 t0, t1, t2;
};

Prism makePrism(Tri tri, float hMin, float hMax)
{
    // Bottom vertices: P_i + N_i * hMin
    // Top vertices: P_i + N_i * hMax
}
```

2. **Ray-Prism Intersection** (lines 195-258):

   - 5 faces: bottom cap, top cap, 3 side quads
   - Each side quad split into 2 triangles
   - Returns entry/exit t values
3. **Key Algorithm Changes**:

   - Initial intersection uses PRISM (not AABB)
   - Ray-prism intersection points projected to UV via inverse displacement
   - Since points are INSIDE prism, inverse displacement is GUARANTEED to converge!
   - Hierarchical traversal also uses prism bounds for sub-regions
4. **Why Prism Solves Tearing** (Paper Section 3, Fig 4):

   > "The key advantage of using a prism as a 3D bounding primitive over a simple
   > axis-aligned box is that it is fully contained inside the convergence region,
   > providing the guarantee that all our projections will fall inside the base triangle."
   >

   With AABB, some 3D points may be outside the convergence region of inverse
   displacement, causing the projection to fail or return incorrect UV coords.
   This is the root cause of tearing in V7-V9.

**Build Status**: ✅ Compiled successfully

**Testing Result**: ❌ SEVERE FRAGMENTATION - Surface is shattered with strips/holes everywhere

**Performance**: Fastest among all versions (57 FPS on displaced_plane)

**Screenshots**:

![1764460959378](image/RMIP_texel_log/1764460959378.png)

![1764460970840](image/RMIP_texel_log/1764460970840.png)

![1764460988369](image/RMIP_texel_log/1764460988369.png)

![1764460998610](image/RMIP_texel_log/1764460998610.png)

![1764461017814](image/RMIP_texel_log/1764461017814.png)

![1764461035368](image/RMIP_texel_log/1764461035368.png)

![1764461079092](image/RMIP_texel_log/1764461079092.png)

**Analysis - Root Cause of Fragmentation**:

The `computeUVRegionPrism()` function creates a TRIANGULAR prism from only 3 corners
of a rectangular UV region:

```slang
float2 c0 = baryMin;
float2 c1 = float2(baryMax.x, baryMin.y);
float2 c2 = float2(baryMin.x, baryMax.y);
// Missing c3 = baryMax!
```

This means the 4th corner (baryMax) is NOT covered by the prism. Rays hitting that
area are rejected, causing massive holes.

**Key Insight from Paper**:

The paper uses prism for the **FULL TRIANGLE** bounding only, NOT for rectangular
sub-regions during hierarchical traversal. From the paper:

- "We start by creating a coarse bounding prism for the entire (micro-)triangle"
- Sub-regions use different bounds (likely AABB or affine arithmetic)

**Correct Approach for V10.1**:

1. Use PRISM only for initial full-triangle intersection (guarantees convergence)
2. Use AABB for sub-region hierarchical traversal (like V9)
3. The prism's main benefit is ensuring initial inverse displacement converges

---

### Version 10.1: Hybrid Prism/AABB Implementation (Nov 29, 2025)

**Archive**: `displacement_intersection_v10.slang` (archived before implementing V10.1)

**Goal**: Fix V10's fragmentation by using AABB for sub-regions instead of prism.

**Key Changes**:

1. **Initial intersection**: PRISM (full triangle) - guarantees convergence
2. **Sub-region culling**: AABB - properly covers rectangular UV regions
3. **Bound reduction**: Still uses inverse displacement (may fail for AABB points)

**Code Changes**:

```slang
// V10.1: Use AABB for sub-region hierarchical bounds (prism only for initial)
float3 aabbMin, aabbMax;
if (!computeUVRegionAABB(tri, bound.uvMin, bound.uvMax, hMin, hMax, aabbMin, aabbMax))
    continue;

float regionTEntry, regionTExit;
if (!rayAABBIntersect(rayOrigin, rayDir, aabbMin, aabbMax, regionTEntry, regionTExit))
    continue;
```

**Build Status**: ✅ Compiled successfully

**Testing Result**: ❌ Almost identical tearing as V9

- Same tearing pattern at grazing angles as V9
- Prism for initial intersection + AABB for sub-regions did NOT solve the problem
- The fundamental issue is not prism vs AABB for bounding volumes

**Analysis**: The hybrid prism/AABB approach doesn't address the root cause. The paper describes using **affine arithmetic** for computing mathematically guaranteed 3D bounds from 2D UV regions. Grid sampling (8×8) can miss extrema between sample points, causing the computed bounds to be too tight, which leads to false negative culling and tearing.

**Conclusion**: Need to implement affine arithmetic as the paper describes for V11.

---

### Version 11: Affine Arithmetic Implementation (Nov 29, 2025)

**Goal**: Implement affine arithmetic for computing tight, mathematically guaranteed 3D bounds from 2D UV regions.

**Paper Reference**: "Tessellation-Free Displacement Mapping for Ray Tracing" (Thonat et al., SIGGRAPH 2021)

- Appendix A contains affine arithmetic formulas
- Key equations: 11 (height affine form), 12 (UV domain), 13 (AABB extraction)

**Key Insight**: Grid sampling (V10.1) can miss extrema between sample points. Affine arithmetic provides:

1. **Mathematically guaranteed bounds** - never misses extrema
2. **Exact handling of linear operations** - position interpolation, normal interpolation
3. **Conservative approximation for non-linear operations** - normalization (1/||N||)

**Affine Arithmetic Basics** (from paper Appendix A):

An affine form represents a quantity as:

```
[x] = x_c + x_u*ε_u + x_v*ε_v + x_K*ε_K
```

where:

- `x_c` = center value (constant)
- `x_u` = coefficient for ε_u (texture coordinate u uncertainty)
- `x_v` = coefficient for ε_v (texture coordinate v uncertainty)
- `x_K` = accumulated approximation error
- ε_u, ε_v, ε_K ∈ [-1, 1] are symbolic variables

**Key Equations from Paper**:

- **Eq 11** (Height from minmax mipmap):

  ```
  [h] = [(hMin+hMax)/2, 0, 0, (hMax-hMin)/2]
  ```
- **Eq 12** (UV domain as affine form):

  ```
  [uv] = [uvCenter, uvHalfSize.x, uvHalfSize.y, 0]
  ```
- **Eq 13** (AABB extraction):

  ```
  S ∈ [S_c - |S_u| - |S_v| - S_K, S_c + |S_u| + |S_v| + S_K]
  ```

**Implementation Details** (shaders/displacement_intersection.slang):

1. **Affine Form Structures** (lines 560-576):

   ```slang
   struct AffineScalar { float c, u, v, k; };
   struct AffineVec3 { float3 c, u, v, k; };
   ```
2. **Affine Arithmetic Operations**:

   - `affineAdd()` - Addition (exact)
   - `affineScale()` - Scalar multiplication (exact)
   - `affineMul()` - Multiplication (introduces error)
   - `affineVec3Dot()` - Dot product
   - `affineRsqrt()` - 1/sqrt() using Chebyshev approximation
   - `affineVec3Normalize()` - Normalization (non-linear, uses rsqrt)
3. **Main Function** `computeUVRegionAABB_Affine()` (lines 789-869):

   - Convert UV region to barycentric affine form
   - Compute position P (linear, exact)
   - Compute normal N (linear, exact)
   - Normalize N̂ = N/||N|| (non-linear, approximation)
   - Compute height h from interval (error = half-range)
   - Compute displaced surface S = P + h*N̂
   - Extract AABB from affine form

**Key Differences from V10.1**:

| Aspect             | V10.1 (Grid Sampling)        | V11 (Affine Arithmetic)   |
| ------------------ | ---------------------------- | ------------------------- |
| Sampling           | 8×8 grid + vertices + edges | Analytical                |
| Extrema            | May miss between samples     | Mathematically guaranteed |
| Position bounds    | Sample-based                 | Exact (linear)            |
| Normal bounds      | Sample-based                 | Exact (linear)            |
| Normalization      | Not handled specially        | Chebyshev approximation   |
| Error accumulation | Unbounded                    | Tracked explicitly        |

**Build Status**: ✅ Compiled successfully

**Testing Result**: ❌ Same tearing as V9/V10.1, but **frame rate nearly doubled**

- Same tearing pattern at grazing angles as previous versions
- Frame rate significantly improved (nearly 2× faster than V10.1)
- Affine arithmetic provides tighter bounds → fewer iterations
- But tearing persists, suggesting bounds are not the root cause

![1764466021232](image/RMIP_texel_log/1764466021232.png)

![1764466049909](image/RMIP_texel_log/1764466049909.png)

![1764466070225](image/RMIP_texel_log/1764466070225.png)

![1764466121552](image/RMIP_texel_log/1764466121552.png)

**Analysis**: Despite implementing affine arithmetic for mathematically guaranteed bounds,
V11 still exhibits the same tearing pattern as V9 and V10.1. This suggests the root cause
is NOT in the AABB computation, but rather in one of:

1. **Bound reduction** (line 15 of Algorithm 1) - projecting ray-box hits back to UV
2. **Initial UV bounds** - starting with triangle's full UV footprint instead of ray projection
3. **Texel marching** - tessellation approach vs paper's ψ-guided marching

---

### Version 11 - Option A Testing: Disable Bound Reduction (Nov 29, 2025)

**Hypothesis**: The bound reduction step (lines 1246-1247) might be too aggressive,
cutting off parts of the ray's curved 2D projection.

**Change**: Commented out bound reduction:

```slang
// V7: Bound reduction via inverse displacement (Paper's line 15)
// bound.uvMin = max(bound.uvMin, projUVMin);
// bound.uvMax = min(bound.uvMax, projUVMax);
```

**Testing Result**: ❌ Did NOT fix tearing

- Tearing changed to a different pattern at grazing angles
- Still has visual artifacts, just different shape
- Confirms that bound reduction is NOT the sole cause
- The issue must be elsewhere in the algorithm

**Conclusion**: Bound reduction alone is not the problem. The tearing persists from V8
through V11, suggesting a fundamental algorithm difference from the paper.

---

### Version 12: ψ-Guided Texel Marching (Nov 29, 2025)

**Archive**: `displacement_intersection_v11.slang`

**Goal**: Implement the paper's Section 4.4 texel marching algorithm using ψ sign at
texel corners to determine exit edges.

**Key Insight from Paper (Section 4.4)**:

> "The sign of the implicit form ψ (3) at each texel corner indicates from which edge
> the ray leaves the texel, as illustrated in the inline figure."

**Current V11 Approach** (tessellateUVRegion):

- Tessellate entire UV region into micro-triangles
- Test ALL micro-triangles for intersection
- Inefficient: tests many triangles the ray doesn't pass through

**Paper's Approach** (texel marching with ψ sign):

- Start at the texel containing the ray entry point
- Evaluate ψ at the 4 corners of current texel
- The sign pattern determines which edge the ray exits from:
  - Sign change across an edge → ray crosses that edge
- Move to the adjacent texel across the exit edge
- Continue until ray exits the UV region or hits displaced surface
- Like DDA ray marching, but following the ψ = 0 curve

**Algorithm**:

```
function texelMarch(bound, rayOrigin, rayDir, tri):
    // Find entry texel
    texel = getEntryTexel(bound, rayOrigin, rayDir, tri)

    while texel is inside bound:
        // Evaluate ψ at 4 corners
        ψ00 = psi(tri, texelCorner(0,0), rayOrigin, rayDir)
        ψ10 = psi(tri, texelCorner(1,0), rayOrigin, rayDir)
        ψ01 = psi(tri, texelCorner(0,1), rayOrigin, rayDir)
        ψ11 = psi(tri, texelCorner(1,1), rayOrigin, rayDir)

        // Test displaced surface in this texel
        if intersectDisplacedSurface(texel, ray):
            return hit

        // Determine exit edge from ψ sign pattern
        exit_edge = findExitEdge(ψ00, ψ10, ψ01, ψ11)

        // Move to adjacent texel
        texel = getAdjacentTexel(texel, exit_edge)

    return miss
```

**Exit Edge Determination** (from ψ sign):

- The ray curve ψ = 0 divides the texel
- Corners with different signs are on opposite sides of the curve
- The exit edge is where the sign changes from the entry side

**Implementation Details**: (see shaders/displacement_intersection.slang)

**V12 Implementation**:

1. `findExitEdge()` - Determines exit edge from ψ sign pattern at 4 corners
2. `getOppositeEdge()` - Returns opposite edge for tracking entry when moving
3. `texelMarchWithPsi()` - Main marching function following ψ = 0 curve

**Testing Result**: ❌ Different tearing pattern from V11, orientation-dependent

**Observed Behavior** (on square planes like displaced_plane.gltf):

The plane has edges a-b-c-d. At ~45° viewing angle:

- **Viewing from edge a or c**: ✅ No tearing, looks correct
- **Viewing from edge b or d**: ❌ Centric strip tearing appears
- **Rotating between a↔b or c↔d**: Tearing gradually appears/disappears

At varying viewing angles (from edge a/c direction):

- **Decreasing angle (more grazing)**: ✅ No tearing
- **Increasing angle toward 90°**: ⚠️ Some tearing appears past threshold
- **At 90° (perpendicular to plane)**: ❌ **SEVERE** - Plane splits into 4 quadrants:
  - Bottom-left: Nearly completely vanishes
  - Top-left: Second most missing
  - Bottom-right: Third most missing
  - Top-right: Least missing
  - Strips follow displacement map pattern

![1764468352498](image/RMIP_texel_log/1764468352498.png)

![1764468379321](image/RMIP_texel_log/1764468379321.png)

![1764468433016](image/RMIP_texel_log/1764468433016.png)

![1764468452690](image/RMIP_texel_log/1764468452690.png)

![1764468498010](image/RMIP_texel_log/1764468498010.png)

![1764468512510](image/RMIP_texel_log/1764468512510.png)

![1764468537008](image/RMIP_texel_log/1764468537008.png)

![1764468559757](image/RMIP_texel_log/1764468559757.png)

---

### V12 Tearing Analysis

#### Root Cause: ψ Degeneracy at 90° View

**The Problem**: When viewing perpendicular to the plane, the ray direction D is parallel to the surface normal N.

```
ψ = det(P-O, N, D) = (P-O) · (N × D)
```

When N ∥ D (perpendicular view):

```
N × D ≈ 0  →  ψ ≈ 0 everywhere on the plane
```

**Consequence**: `findExitEdge()` sees no sign changes (all ψ values ≈ 0), returns `EDGE_NONE`.

**Fallback behavior** in `texelMarchWithPsi()`:

```slang
if (exitEdge == EDGE_NONE)
{
    if (currentTexel.x < texelMax.x)
        currentTexel.x++;      // Always march +X first
    else if (currentTexel.y < texelMax.y)
        currentTexel.y++;      // Then +Y
    else
        break;
}
```

This fallback creates **asymmetric marching pattern**:

- Starts at texelMin (bottom-left corner)
- Marches only in +X, +Y directions
- Never visits texels in -X or -Y direction from start
- Result: Bottom-left quadrant mostly missed, top-right mostly covered

#### Edge a/c vs b/d Asymmetry

The plane is made of **2 triangles** with a diagonal from (0,0) to (1,1) in UV space:

- Triangle 1: UV corners (0,0), (1,0), (1,1) - lower-right
- Triangle 2: UV corners (0,0), (1,1), (0,1) - upper-left

When viewing from different edges at 45°:

- **Edge a/c** (parallel to UV diagonal): ψ curve aligns well with texel marching
- **Edge b/d** (perpendicular to UV diagonal): ψ curve crosses texel boundaries at bad angles

The ψ = 0 curve is a **quadric** in UV space. When the ray direction causes this quadric to:

- Align with texel grid: Sign changes detected reliably
- Run parallel to texel edges: Sign changes may be missed (ψ ≈ 0 along entire edge)

#### Why This Didn't Happen in V11 (tessellation)

V11's `tessellateUVRegion()` tests **ALL texels** in the UV region:

```slang
for (int iu = 0; iu < res; iu++)
    for (int iv = 0; iv < res; iv++)
        // Test every texel
```

V12's `texelMarchWithPsi()` only follows the ψ = 0 curve:

- More efficient when ψ is well-behaved
- **Fails when ψ is degenerate** (near-zero everywhere)

#### Potential Fixes

1. **Hybrid approach**: Fall back to tessellation when ψ is degenerate

   ```slang
   // Detect degenerate case
   float maxPsi = max(max(abs(psi00), abs(psi10)), max(abs(psi01), abs(psi11)));
   if (maxPsi < PSI_THRESHOLD)
       return tessellateUVRegion(...);  // Fall back
   ```
2. **Better fallback marching**: When EDGE_NONE, use DDA-style grid traversal instead of +X/+Y only
3. **ψ normalization**: Scale ψ values to improve numerical stability at grazing/perpendicular angles
4. **Paper's approach**: The paper may handle this by not using ψ-guided marching when |N × D| is small

---

## V12 vs Paper Comparison

### Comprehensive Feature Comparison

| Feature                                                   | Paper (RMIP)                    | V12 Implementation                                                   | Status  |
| --------------------------------------------------------- | ------------------------------- | -------------------------------------------------------------------- | ------- |
| **Eq 1**: Displaced surface S(u,v) = P + h·N̂     | ✓                              | ✓`getP()`, `getN()`, displacement sampling                      | ✅ Same |
| **Eq 2**: Inverse displacement (P-Q)×N = 0         | ✓ Newton iteration             | ✓`inverseDisplacement()` with Newton                              | ✅ Same |
| **Eq 3**: Implicit ray projection ψ = det(P-O,N,D) | ✓                              | ✓`psi()` function                                                 | ✅ Same |
| **Eq 4**: ψ partial derivatives ψ_u, ψ_v         | ✓                              | ✓`psiGrad()` function                                             | ✅ Same |
| **Bounding prism** (6 vertices)                     | ✓ For initial intersection     | ✓`Prism` struct, `makePrism()`                                  | ✅ Same |
| **Ray-prism intersection**                          | ✓ 5 faces (2 caps + 3 quads)   | ✓`rayPrismIntersect()`                                            | ✅ Same |
| **Stack-based traversal**                           | ✓ Front-to-back                | ✓`UVBound stack[]`                                                | ✅ Same |
| **Affine arithmetic for 3D bounds**                 | ✓ Appendix A of TFDM           | ✓`AffineScalar`, `AffineVec3`, `computeUVRegionAABB_Affine()` | ✅ Same |
| **Bound reduction (line 15)**                       | ✓ Project ray-box hits to UV   | ✓ Via `inverseDisplacement()`                                     | ✅ Same |
| **Turning point detection**                         | ✓ Find ψ_u=0, ψ_v=0          | ✓`findTurningPointsInRegion()`                                    | ✅ Same |
| **ψ-guided texel marching (Section 4.4)**          | ✓ Sign at corners → exit edge | ✓`texelMarchWithPsi()`, `findExitEdge()`                        | ✅ Same |

### Potential Differences (Areas to Investigate)

| Aspect                                 | Paper                                           | V12                                                     | Potential Issue               |
| -------------------------------------- | ----------------------------------------------- | ------------------------------------------------------- | ----------------------------- |
| **RMIP queries**                 | Query RMIP for tight displacement bounds        | Uses conservative global bounds (0, DISPLACEMENT_SCALE) | ❌**NOT USING RMIP**    |
| **Initial UV bounds**            | Project ray-prism intersection to UV            | Start with triangle's full UV bbox, then reduce         | ⚠️ Different initialization |
| **Bound subdivision**            | Split using ψ=0 line intersection with midline | Split along longer UV dimension geometrically           | ⚠️ Less precise             |
| **Texel marching entry**         | From inverse displacement of ray entry          | Fallback to corner if inverse fails                     | ⚠️ May start wrong texel    |
| **Micro-surface reconstruction** | Bilinear height interpolation                   | Two micro-triangles per texel                           | ✅ Equivalent                 |

### Key Equations Verification

#### Eq 3: ψ(u,v) = det(P-O, N, D) = 0

**Paper**: "This is a quadric in texture space"

**V12 Implementation** (`psi()` function):

```slang
float psi(Tri tri, float2 bary, float3 rayO, float3 rayD)
{
    float3 P = getP(tri, bary);
    float3 N = getN(tri, bary);
    float3 NxD = cross(N, rayD);
    return dot(P - rayO, NxD);  // = det(P-O, N, D)
}
```

✅ **Correct** - Uses scalar triple product identity: det(A,B,C) = A·(B×C)

#### Section 4.4: Texel Marching with ψ Sign

**Paper**: "The sign of the implicit form ψ (3) at each texel corner indicates from which edge the ray leaves the texel"

**V12 Implementation** (`findExitEdge()`):

```slang
bool crossLeft   = (psi00 * psi01 < 0.0);  // Sign change = ray crosses
bool crossRight  = (psi10 * psi11 < 0.0);
bool crossBottom = (psi00 * psi10 < 0.0);
bool crossTop    = (psi01 * psi11 < 0.0);
```

✅ **Correct** - Sign change across edge means ψ=0 curve crosses that edge

### Critical Missing Feature: RMIP Queries

**Paper (Section 5)**: "RMIP structure provides displacement bounds for arbitrary axis-aligned rectangular regions"

**V12 Implementation** (`getDisplacementBounds()`):

```slang
void getDisplacementBounds(uint matIdx, float2 texMin, float2 texMax, int2 texSize,
                           out float hMin, out float hMax)
{
    // Conservative global bounds (like brute force)
    hMin = 0.0;
    hMax = DISPLACEMENT_SCALE;
}
```

❌ **NOT USING RMIP** - Returns global bounds instead of querying RMIP structure

**Impact**: Without tight displacement bounds from RMIP:

- 3D AABBs are larger than necessary
- Less effective space culling during hierarchical traversal
- More iterations needed to reach leaf level
- BUT should NOT cause tearing (bounds are conservative, not aggressive)

### Root Cause Analysis

The tearing artifacts persist through V8-V12 despite implementing:

- ✅ Inverse displacement (Eq 2)
- ✅ Implicit ray projection ψ (Eq 3)
- ✅ Turning point detection (Eq 4)
- ✅ Bound reduction via inverse displacement
- ✅ Affine arithmetic for 3D bounds
- ✅ Bounding prism for initial intersection
- ✅ ψ-guided texel marching (Section 4.4)

**Remaining hypotheses for tearing**:

1. **Inverse displacement convergence** - Newton iteration may not converge for some 3D points, even inside prism. Paper says prism guarantees convergence, but our prism construction may differ.
2. **Bound reduction too aggressive** - When inverse displacement gives slightly wrong UV, the reduced bounds may exclude valid regions.
3. **Texel marching entry point** - If we start at wrong texel, we may miss the actual ray path.
4. **Triangle domain handling** - The paper works purely in texture space; we convert between texture and barycentric which introduces the u+v≤1 constraint complications.
5. **Numerical precision** - Floating-point issues at grazing angles where ψ values are very small.

---

## Testing Notes

### Test Models

- displaced_plane_vertical.gltf (512x512 simple bump)
- displaced_108_hex_grid_random_4.gltf (512x512 hex grid pattern)
- displaced_114_organic_scale.gltf (512x512 organic scales)
- displaced_120_quilted_fabric.gltf (512x512 quilted fabric)
- displaced_121_chipped_planks.gltf (512x512 wood planks)

### Known Working Reference

- `others/RMIP_texel/displacement_intersection_bf.slang` - Brute force tessellation in barycentric space (works correctly)

![1764445100795](image/RMIP_texel_log/1764445100795.png)

---

## V12 Deep Analysis: ψ Degeneracy Problem (Nov 29, 2025)

### Paper's Section 4.4 Texel Marching - Detailed Analysis

**Paper Quote**: "The sign of the implicit form ψ (3) at each texel corner indicates from which edge the ray leaves the texel"

**Equation 3**: `ψ(u,v) = det(P(u,v) - O, N(u,v), D) = (P-O) · (N×D) = 0`

The ψ = 0 curve is where the **projected ray** passes through in texture space. This is NOT the ray itself - it's the ray's "shadow" projected along displacement directions onto the UV plane.

**Key Properties of ψ**:

1. ψ is a **quadric** in UV space (bilinear interpolation of P and N)
2. ψ = 0 defines a curve (the projected ray) in UV
3. ψ > 0 on one side of the curve, ψ < 0 on the other
4. Sign changes at texel corners → ψ = 0 curve crosses that edge

### The Degenerate Case: D ∥ N (Perpendicular View)

**When viewing perpendicular to the plane**:

- Ray direction D is parallel to surface normal N
- `N × D ≈ 0` (cross product of parallel vectors)
- `ψ = (P-O) · (N×D) ≈ 0` **everywhere** on the surface!

**Consequence**: All 4 texel corners have ψ ≈ 0, no sign changes detected, `findExitEdge()` returns `EDGE_NONE`.

### Paper's Implicit Handling of Degenerate Case

The paper doesn't explicitly address ψ degeneracy, but several mechanisms should prevent it:

**1. Section 4.3 Quote**: "Rays that are near-parallel to the displacement directions have 2D projections smaller than the size of a texel."

For perpendicular rays (D ∥ N):

- The ray is nearly parallel to the displacement directions
- The inverse displacement projection should give a **tiny** UV region
- This region would be smaller than MARCHING_SCALE
- The hierarchical traversal should reduce bounds to ≤1 texel
- **Texel marching would only handle 1-2 texels, not traverse the whole surface**

**2. Algorithm 1 Line 3**: `bounds = inverse_displacement(points, triangle)`

For perpendicular rays:

- Entry point and exit point project to **nearly the same UV**
- Initial UV bounds are tiny
- We go directly to texel testing without needing ψ-guided marching

**3. Hierarchical Bound Reduction (Lines 12-15)**:

Each iteration:

- Computes 3D bounds using affine arithmetic
- Intersects ray with 3D bounds → gets tighter [tEntry, tExit]
- Projects these back to UV via inverse displacement
- For perpendicular rays, this should converge to a small UV region quickly

### V12's Problem: Large UV Bounds with Degenerate ψ

**V12's Initialization** (lines 1709-1729):

```slang
float2 initialUVMin = triUVMin;
float2 initialUVMax = triUVMax;

if (validEntry && validExit)
{
    float2 uvEntry = baryToTex(tri, baryEntry);
    float2 uvExit = baryToTex(tri, baryExit);
    initialUVMin = min(uvEntry, uvExit);
    initialUVMax = max(uvEntry, uvExit);
    // Add 10% padding + 0.01 absolute padding
}
```

**Problem**: For perpendicular rays hitting a **non-flat displacement**:

- Ray-prism intersection gives entry at h_max and exit at h_min (or vice versa)
- These 3D points are at DIFFERENT heights along the displacement
- Inverse displacement projects them to DIFFERENT UV locations
- Result: UV bounds can still be LARGE even for perpendicular rays!

**Why?** Consider a ray perpendicular to a plane with varying displacement:

- Entry at (x, y, h_max) projects to UV_a
- Exit at (x, y, h_min) projects to UV_b
- If h_max and h_min occur at different UV locations, UV_a ≠ UV_b
- Initial bounds = max(UV_a, UV_b) can span a large region

**Then**: When texel marching starts with large UV region and ψ is degenerate:

- `findExitEdge()` returns EDGE_NONE for every texel
- Fallback marches +X, +Y only → misses many texels
- Result: Tearing in the pattern we observed

### V12's Fallback Marching Problem

**Current Fallback** (`texelMarchWithPsi()` lines 1486-1497):

```slang
if (exitEdge == EDGE_NONE)
{
    // No valid exit - try moving in a default direction
    if (currentTexel.x < texelMax.x)
        currentTexel.x++;
    else if (currentTexel.y < texelMax.y)
        currentTexel.y++;
    else
        break;
}
```

**Issues**:

1. Only moves in +X, +Y directions (never -X, -Y)
2. If entry texel is in the middle, can't reach texels in -X or -Y direction
3. Creates asymmetric coverage → asymmetric tearing pattern

### Proposed Fixes

#### Fix 1: Detect ψ Degeneracy and Fall Back to Tessellation

**Idea**: Check |N × D| before texel marching. If degenerate, use tessellation.

```slang
bool texelMarchWithPsi(...)
{
    // Check for ψ degeneracy (N ∥ D)
    float3 avgN = normalize(tri.n0 + tri.n1 + tri.n2);
    float NcrossD = length(cross(avgN, rayD));

    if (NcrossD < PSI_DEGENERACY_THRESHOLD)
    {
        // Fall back to tessellation for perpendicular rays
        return tessellateUVRegion(tri, matIdx, rayO, rayD,
                                  uvMin, uvMax, rayTMin, rayTMax,
                                  texSize, hitT, hitBary, hitGeoNormal);
    }

    // Normal ψ-guided marching
    ...
}
```

**Threshold**: `PSI_DEGENERACY_THRESHOLD ≈ 0.1` (sin(~6°))

#### Fix 2: DDA-Style Fallback Marching

**Idea**: When EDGE_NONE, use proper DDA grid traversal based on ray direction projected to UV.

```slang
if (exitEdge == EDGE_NONE)
{
    // Project ray direction to UV space for DDA marching
    float2 uvDir = computeRayDirectionInUV(tri, rayO, rayD, currentTexel);

    // Move in the dominant direction
    if (abs(uvDir.x) >= abs(uvDir.y))
        currentTexel.x += (uvDir.x >= 0) ? 1 : -1;
    else
        currentTexel.y += (uvDir.y >= 0) ? 1 : -1;
}
```

This ensures marching follows the actual ray path even when ψ is degenerate.

#### Fix 3: Tighter Initial UV Bounds for Perpendicular Rays

**Idea**: When D ≈ N, use a different initialization strategy.

```slang
float NdotD = abs(dot(normalize(tri.n0 + tri.n1 + tri.n2), rayD));

if (NdotD > 0.9)  // Ray nearly perpendicular to surface
{
    // For perpendicular rays, the UV footprint is small
    // Use the actual displaced surface intersection point
    float3 Q_mid = rayOrigin + (prismTEntry + prismTExit) * 0.5 * rayDir;
    float2 baryMid;
    if (inverseDisplacement(tri, Q_mid, baryMid))
    {
        float2 uvMid = baryToTex(tri, baryMid);
        // Use tight bounds around this point
        float2 uvPadding = float2(2.0) / float2(texSize);  // ~2 texels
        initialUVMin = uvMid - uvPadding;
        initialUVMax = uvMid + uvPadding;
    }
}
```

#### Fix 4: Hybrid Approach (Recommended)

Combine all three fixes:

1. **Check ψ degeneracy** at start of texel marching
2. **If degenerate**: Fall back to tessellation
3. **If not degenerate but EDGE_NONE**: Use DDA-style marching
4. **Better initialization**: Tighter bounds for perpendicular rays

### Summary

**Root Cause**: ψ(u,v) = (P-O)·(N×D) becomes degenerate when N ∥ D (perpendicular view).

**Paper's Implicit Handling**: Relies on tight initial UV bounds from inverse displacement, which should be small for perpendicular rays. Texel marching only handles the final few texels.

**V12's Problem**: Initial UV bounds can be large even for perpendicular rays (due to displacement variation). When texel marching starts with large bounds and degenerate ψ, the fallback (+X, +Y only) misses texels.

**Fix**: Detect ψ degeneracy and fall back to tessellation, or use DDA-style marching when ψ is degenerate.

---

### Version 13: ψ Degeneracy Detection with Tessellation Fallback (Nov 29, 2025)

**Archive**: `displacement_intersection_v12.slang`

**Goal**: Fix V12's tearing at perpendicular viewing angles by detecting ψ degeneracy.

**Implementation** (shaders/displacement_intersection.slang):

1. **Added constant** (line 41):

```slang
// V13: ψ degeneracy threshold - when |N × D| < this, fall back to tessellation
// sin(6°) ≈ 0.1 - detects rays within ~6° of perpendicular to surface
static const float PSI_DEGENERACY_THRESHOLD = 0.1;
```

2. **Added degeneracy check** in `texelMarchWithPsi()` (lines 1366-1375):

```slang
// V13: Check for ψ degeneracy (N ∥ D)
// When ray is perpendicular to surface, N × D ≈ 0, so ψ ≈ 0 everywhere.
// Sign-based edge detection fails → fall back to tessellation.
float3 avgN = normalize(tri.n0 + tri.n1 + tri.n2);
float NcrossD = length(cross(avgN, rayD));

if (NcrossD < PSI_DEGENERACY_THRESHOLD)
{
    // ψ is degenerate - fall back to tessellation
    return tessellateUVRegion(tri, matIdx, rayO, rayD,
                              uvMin, uvMax, rayTMin, rayTMax,
                              texSize, hitT, hitBary, hitGeoNormal);
}
```

3. **Added forward declaration** for `tessellateUVRegion()` (lines 1331-1335)

**Build Status**: ✅ Compiled successfully

**Testing Result**: ❌ **FAILED** - Combines tearing from BOTH methods

![1764470693508](image/RMIP_texel_log/1764470693508.png)

PSI_DEGENERACY_THRESHOLD = 0.1
![1764470715404](image/RMIP_texel_log/1764470715404.png)

PSI_DEGENERACY_THRESHOLD = 0.2
![1764470783670](image/RMIP_texel_log/1764470783670.png)

PSI_DEGENERACY_THRESHOLD = 0.3
![1764470873561](image/RMIP_texel_log/1764470873561.png)

**Analysis of V13 Failure**:

Instead of fixing tearing, V13 **combines two different tearing patterns**:

1. **Original ψ-marching tearing** (at ~45° viewing angle from edges b/d)
2. **NEW tessellation fallback tearing** (circular "four arrows" pattern at center at 90° view)

**Observations**:

- At ~45° angle: Fix did almost nothing, same tearing as V12
- At 90° (perpendicular): Central circular area shows tessellation tearing
- As PSI_DEGENERACY_THRESHOLD increases (0.1 → 0.2 → 0.3):
  - The circular tessellation-tearing area grows larger
  - At 0.3, almost entire model shows tessellation tearing at vertical view

**Root Cause**: `tessellateUVRegion()` ALSO has tearing issues!

Looking at `tessellateUVRegion()`:

```slang
float2 uvSize = (uvMax - uvMin) * float2(texSize);
int res = int(max(uvSize.x, uvSize.y)) + 1;
res = clamp(res, 2, 8);  // ← Resolution clamped to MAX 8!
```

Problems:

1. **Low resolution**: Only 8×8 = 64 samples max, can miss intersection
2. **UV bounds may be wrong**: Hierarchical traversal may pass incorrect bounds
3. **Rectangular UV grid**: Doesn't properly handle triangular barycentric domain

**Conclusion**: Falling back to `tessellateUVRegion()` doesn't work because:

- The UV bounds from hierarchical traversal may already be wrong
- The tessellation resolution is too low
- The method itself has issues at leaf level

**Next Approach (V14)**: Instead of detecting degeneracy at leaf level and falling back to
a broken tessellation, detect degeneracy at the START (before hierarchical traversal) and
bypass the entire hierarchical system, using brute force on the whole triangle instead.

---

### Version 14: Full Brute Force Bypass at START (Nov 29, 2025)

**Archive**: `displacement_intersection_v13.slang`

**Goal**: Fix V13's combined tearing by detecting degeneracy at START and bypassing entire system.

**Key Insight**: V13 failed because:

1. `tessellateUVRegion()` was also broken (max 8×8 resolution, UV space issues)
2. Detecting degeneracy at leaf level doesn't help if the hierarchical traversal already corrupted bounds

**V14 Approach**:

1. Detect ψ degeneracy at START (right after prism intersection)
2. When degenerate, BYPASS entire hierarchical system
3. Use working brute force (barycentric triangular tessellation, 64×64 resolution)
4. Return immediately without entering hierarchical traversal

**Implementation** (shaders/displacement_intersection.slang):

1. **Added `bruteForceBarycentric()` function** (lines 1665-1751):

   - Exact copy of working bf.slang logic
   - Barycentric space with triangular tessellation pattern
   - 64×64 resolution (not 8×8 like tessellateUVRegion)
   - Properly handles u + v <= 1 constraint
2. **Added degeneracy check at START** (lines 1832-1864):

```slang
// V14: Check for ψ degeneracy at START (before hierarchical traversal)
float3 avgN = normalize(tri.n0 + tri.n1 + tri.n2);
float NcrossD = length(cross(avgN, rayDir));

if (NcrossD < PSI_DEGENERACY_THRESHOLD)
{
    // ψ is degenerate - bypass entire hierarchical system with brute force
    if (bruteForceBarycentric(tri, matIdx, rayOrigin, rayDir,
                              prismTEntry, prismTExit, texSize,
                              hitT, hitBary, hitGeoNormal))
    {
        // Report hit and return
    }
    return;  // Don't continue with hierarchical traversal
}
```

3. **Removed degeneracy check from `texelMarchWithPsi()`** - no longer needed

**Why V14 Should Work**:

- Brute force (bf.slang) is PROVEN to work correctly
- By detecting degeneracy at START, we completely avoid the problematic paths
- For non-degenerate rays, we still use the efficient ψ-guided marching

**Build Status**: ✅ Compiled successfully

**Testing Result**: ❌ **FAILED** - bd edge tearing is NOT caused by ψ degeneracy

![1764471982671](image/RMIP_texel_log/1764471982671.png)

![1764472007780](image/RMIP_texel_log/1764472007780.png)

**Analysis of V14 Failure**:

1. **bd edge tearing UNCHANGED**: The circular/strip tearing when viewing from edges b/d at ~45° has NOT changed at all. This proves definitively that **this tearing is NOT caused by ψ degeneracy**.
2. **Vertical view (90°)**: Creates a central disk replaced by brute force that scales with PSI_DEGENERACY_THRESHOLD. The brute force area shows its own problems - visible triangles across the render.
3. **Key Conclusion**: The ψ degeneracy hypothesis was WRONG for the bd edge tearing. The issue must be something else entirely.

**What We've Learned**:

| Tearing Type                  | ψ Degeneracy Related? | Evidence                             |
| ----------------------------- | ---------------------- | ------------------------------------ |
| Vertical (90°) view tearing  | Yes (partially)        | Brute force bypass changes this area |
| bd edge (~45°) strip tearing | **NO**           | V14 bypass did NOT fix this at all   |

**Root Cause Must Be Something Else**:

Since the bd edge tearing persists even when ψ is NOT degenerate (|N×D| > 0.3), the issue is NOT with ψ sign detection. Possible causes:

1. **`findExitEdge()` logic bug**: Maybe the exit edge determination is wrong in certain cases even when ψ signs are valid
2. **Entry texel finding**: The initial texel from inverse displacement may be wrong
3. **Texel marching loop bug**: Off-by-one errors, wrong direction handling
4. **UV-to-barycentric conversion issues**: `texToBary()` or `baryToTex()` may have edge cases
5. **Triangle diagonal alignment**: The plane's two triangles have different orientations

**Next Investigation**: Abandon ψ degeneracy approach. Look at the texel marching algorithm itself - specifically `findExitEdge()` and the marching loop logic.

---

### BUG FOUND: ψ Computed on CLAMPED Barycentric Coordinates!

**Discovery** (during V14 analysis):

Looking at `texelMarchWithPsi()` lines 1427-1502:

```slang
// Line 1427-1431: Convert UV corners to barycentric (ORIGINAL values)
float2 b00, b10, b01, b11;
texToBary(tri, uv00, b00);
texToBary(tri, uv10, b10);
...

if (valid00 || valid10 || valid01 || valid11)
{
    // Line 1443-1446: CLAMP - this MODIFIES b00, b10, b01, b11!
    b00 = clampBary(b00);
    b10 = clampBary(b10);
    b01 = clampBary(b01);
    b11 = clampBary(b11);

    // ... micro-triangle intersection tests ...
}

// Line 1498-1502: ψ computed using the CLAMPED values!
float psi00 = psi(tri, b00, rayO, rayD);  // ← CLAMPED!
float psi10 = psi(tri, b10, rayO, rayD);  // ← CLAMPED!
...
```

**The Bug**:

1. When the if block is entered, b00, b10, b01, b11 are CLAMPED
2. The ψ computation happens AFTER the if block, using the CLAMPED values
3. Clamped corners might all collapse to similar positions (e.g., all on the u+v=1 edge)
4. This makes ψ values nearly equal → NO sign changes detected → EDGE_NONE
5. EDGE_NONE triggers the fallback marching (+X, +Y only) → tearing!

**Why This Causes Asymmetric Tearing**:

- Texels at the triangle edge are affected
- Different viewing angles cause different texels to be at the edge
- Viewing from edge a/c vs b/d affects which texels get clamped
- This explains why the tearing pattern depends on viewing direction!

**Fix (V15)**: Save the ORIGINAL unclamped values before clamping, and use those for ψ computation:

```slang
// Save original unclamped values for ψ
float2 b00_orig = b00, b10_orig = b10, b01_orig = b01, b11_orig = b11;

if (valid00 || valid10 || valid01 || valid11)
{
    // Clamp for micro-triangle intersection only
    b00 = clampBary(b00);
    ...
}

// Use ORIGINAL values for ψ
float psi00 = psi(tri, b00_orig, rayO, rayD);
...
```

---

### Version 15: Fix ψ Computation on Unclamped Barycentric Coordinates (Nov 29, 2025)

**Implementation of the Fix** (from bug found in V14 analysis):

The bug was that ψ values were computed on CLAMPED barycentric coordinates. When texel corners
outside the triangle domain get clamped to the edge, multiple corners collapse to similar positions,
causing ψ values to become nearly equal → no sign changes → EDGE_NONE → broken traversal.

**V15 Changes**:

1. Save original unclamped barycentric values before clamping
2. Use clamped values ONLY for micro-triangle intersection (correct behavior)
3. Use ORIGINAL unclamped values for ψ computation

**Code Changes** (`texelMarchWithPsi()` lines 1433-1439, 1506-1511):

```slang
// V15 FIX: Save original unclamped values for ψ computation
// ψ must be computed on original positions, not clamped ones!
// Clamping moves multiple corners to the same edge position → similar ψ values
float2 b00_orig = b00;
float2 b10_orig = b10;
float2 b01_orig = b01;
float2 b11_orig = b11;

// ... later, clamping happens for micro-triangle intersection only ...

// V15 FIX: Compute ψ at all 4 corners using ORIGINAL unclamped values
// Using clamped values caused multiple corners to have similar ψ → EDGE_NONE
float psi00 = psi(tri, b00_orig, rayO, rayD);
float psi10 = psi(tri, b10_orig, rayO, rayD);
float psi01 = psi(tri, b01_orig, rayO, rayD);
float psi11 = psi(tri, b11_orig, rayO, rayD);
```

**Other Changes**:

- Removed V14 bypass code (user requested no fallback/bypass methods)
- Removed `bruteForceBarycentric()` function (no longer used)
- Removed `PSI_DEGENERACY_THRESHOLD` constant (no longer used)

**Testing**: Build successful.

**Result**: FAILED - No change from V12. Same strip tearing pattern.

**V15 Screenshots** (viewing angle transition from edge a to edge b):

![1764475730552](image/RMIP_texel_log/1764475730552.png)
*Pic 1: View from edge a - clean, no artifacts*

![1764475747683](image/RMIP_texel_log/1764475747683.png)
*Pic 2: ~22° rotation - strips START appearing from RIGHT corner, spreading left*

![1764475764380](image/RMIP_texel_log/1764475764380.png)
*Pic 3: 45° diagonal - right half filled with concentric strips, left half sparse*

![1764475787822](image/RMIP_texel_log/1764475787822.png)
*Pic 4: ~67° rotation - strips spread across entire surface*

![1764475801783](image/RMIP_texel_log/1764475801783.png)
*Pic 5: View from edge b - entire surface covered with concentric ring patterns*

**Analysis of V15 Failure**:

The clamping fix had no effect because the REAL issue is elsewhere. Key observations:

1. **The strips ARE the ψ=0 isolines** - they follow contour lines of ψ, centered on bump peaks
2. **Pattern spreads from vertices** - strips emanate radially from bump centers
3. **View-dependent asymmetry** - edge a works, edge b fails

**Root Cause Identified: Fixed Priority in findExitEdge()**

Looking at the code:

```slang
// Line 515-518: Fixed priority when multiple exits exist
if (crossRight && entryEdge != EDGE_RIGHT)   return EDGE_RIGHT;
if (crossTop && entryEdge != EDGE_TOP)       return EDGE_TOP;
if (crossLeft && entryEdge != EDGE_LEFT)     return EDGE_LEFT;
if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
```

This has a **FIXED BIAS: right > top > left > bottom**.

- When viewing from edge a, the ray naturally travels toward right/top → priority works
- When viewing from edge b, the ray travels toward left/bottom → priority picks WRONG direction!

**Why This Causes Strips**:

When ψ≈0 at multiple corners (near the ψ=0 curve):

1. Multiple edges detect sign changes (2, 3, or even 4)
2. Priority picks right/top even when ray actually exits left/bottom
3. Marching goes WRONG direction → misses texels → gaps appear
4. Gaps form along ψ=0 contours → concentric strip pattern

**Solution for V16**: Use ψ gradient to determine correct exit direction instead of fixed priority.

The gradient ∇ψ = (ψu, ψv) is perpendicular to the ψ=0 curve. The tangent to the curve is (-ψv, ψu).
By checking which direction along the curve corresponds to increasing ray parameter t, we can
determine the correct exit edge.

---

### Version 16: Gradient-Based Exit Edge Selection (Nov 29, 2025)

**Implementation of the Gradient-Based Fix**:

Instead of fixed priority (right > top > left > bottom), V16 uses the ψ gradient to determine
which exit edge is correct based on the curve's direction of travel.

**V16 Changes**:

1. Modified `findExitEdge()` to take an additional `float2 grad` parameter
2. Compute gradient at texel center: `grad = psiGrad(tri, baryCenter, rayO, rayD)`
3. Compute curve tangent: `tangent = (-grad.y, grad.x)` (perpendicular to gradient)
4. Use tangent direction to determine priority:
   - If `tangent.x > 0`: curve moves right → prefer RIGHT over LEFT
   - If `tangent.x < 0`: curve moves left → prefer LEFT over RIGHT
   - If `tangent.y > 0`: curve moves up → prefer TOP over BOTTOM
   - If `tangent.y < 0`: curve moves down → prefer BOTTOM over TOP

**Code Changes** (`findExitEdge()` lines 486-603):

```slang
int findExitEdge(float psi00, float psi10, float psi01, float psi11, int entryEdge, float2 grad)
{
    // ... crossing detection same as before ...

    // V16: Two or more crossings - use gradient to determine correct exit
    float2 tangent = float2(-grad.y, grad.x);

    if (abs(tangent.x) > abs(tangent.y))
    {
        // Curve moves primarily horizontally
        if (tangent.x > 0)
        {
            // Moving right: right > top/bottom > left
            if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
            // ... secondary priorities based on tangent.y ...
        }
        else
        {
            // Moving left: left > top/bottom > right
            if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
            // ...
        }
    }
    else
    {
        // Curve moves primarily vertically - similar logic
    }
}
```

**Call Site Update** (`texelMarchWithPsi()` lines 1585-1590):

```slang
// V16: Compute gradient at texel center for direction-aware exit selection
float2 baryCenter = (b00_orig + b10_orig + b01_orig + b11_orig) * 0.25;
float2 grad = psiGrad(tri, baryCenter, rayO, rayD);

// Find exit edge using gradient-based priority
int exitEdge = findExitEdge(psi00, psi10, psi01, psi11, entryEdge, grad);
```

**Testing**: Build successful.

**Result**: PARTIAL - Changed behavior but didn't fix the problem!

- Before V16: edge ac good, edge bd bad
- After V16: edge ab good, edge cd bad
- The problem ROTATED 90° instead of being fixed!

**Analysis of V16 Failure**:

The tangent `(-grad.y, grad.x)` gives ONE direction along the curve, but there are TWO possible
directions. We arbitrarily picked one, but we need to pick the one that's CONSISTENT with the
ray's direction of travel.

The issue: the tangent direction should match how we ENTERED the texel:

- If entryEdge == LEFT: we're moving in +u direction → tangent.x should be > 0
- If entryEdge == RIGHT: we're moving in -u direction → tangent.x should be < 0
- If entryEdge == BOTTOM: we're moving in +v direction → tangent.y should be > 0
- If entryEdge == TOP: we're moving in -v direction → tangent.y should be < 0

**Solution for V17**: Flip the tangent if it's inconsistent with the entry direction.

---

### Version 17: Entry-Consistent Tangent Direction (Nov 29, 2025)

**The Fix**:

V16's tangent `(-grad.y, grad.x)` gives ONE direction along the curve, but there are TWO possible
directions. V17 checks if the tangent is consistent with the entry edge and flips it if not.

**V17 Changes** (`findExitEdge()` lines 513-526):

```slang
// V17 FIX: Flip tangent if inconsistent with entry direction
bool needFlip = false;
if (entryEdge == EDGE_LEFT && tangent.x < 0) needFlip = true;
else if (entryEdge == EDGE_RIGHT && tangent.x > 0) needFlip = true;
else if (entryEdge == EDGE_BOTTOM && tangent.y < 0) needFlip = true;
else if (entryEdge == EDGE_TOP && tangent.y > 0) needFlip = true;

if (needFlip)
    tangent = -tangent;
```

**Logic**:

- Entry LEFT → we're moving in +u direction → tangent.x should be > 0, else flip
- Entry RIGHT → we're moving in -u direction → tangent.x should be < 0, else flip
- Entry BOTTOM → we're moving in +v direction → tangent.y should be > 0, else flip
- Entry TOP → we're moving in -v direction → tangent.y should be < 0, else flip

**Testing**: Build successful. Awaiting visual verification.

**Expected Result**:

- Tangent direction now consistent with ray's direction of travel
- All edges (a, b, c, d) should work correctly
- No more rotated problem pattern

**Result**: FAILED - No change from V16!

Screenshots (a-b-c-d-top sequence):

- Edge a: strips on left side (bad)
- Edge b: clean (good)
- Edge c: heavy concentric strip patterns (bad)
- Edge d: heavy concentric strip patterns (bad)
- Top view: ab good, cd bad (same as V16)

The entry-direction flip logic had NO EFFECT. This means the entry edge doesn't actually
determine the correct tangent direction - the relationship between entry edge and curve
direction is more complex than assumed.

---

### Version 18: Ray Direction Projection into Texture Space (Nov 29, 2025)

**Key Insight**:

The gradient-based approaches (V16, V17) don't work because:

1. The gradient ∇ψ is PERPENDICULAR to the ψ=0 curve, not along it
2. The tangent (-grad.y, grad.x) gives ONE direction, but there are TWO
3. Neither the entry edge nor the gradient alone determines which direction is "forward"

**New Approach**: Project the ray direction D directly into texture (UV) space!

The ray has a definite direction in 3D world space. By projecting it onto the triangle's
tangent plane and expressing it in UV coordinates, we get the TRUE direction of travel
through texels - no guessing or flipping needed.

**Method**:

1. Triangle tangent plane is spanned by dPdu and dPdv
2. Project ray direction: D_proj = D - (D·N)*N
3. Express in UV: solve D_proj ≈ rayDirUV.x * dPdu + rayDirUV.y * dPdv
4. Use Gram matrix: G = [dPdu·dPdu  dPdu·dPdv; dPdu·dPdv  dPdv·dPdv]
5. rayDirUV = G^(-1) * [D_proj·dPdu, D_proj·dPdv]

**V18 New Function** (`computeRayDirUV()` lines 467-499):

```slang
float2 computeRayDirUV(Tri tri, float3 rayD)
{
    // Triangle normal from edge cross product
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
        return float2(b0, b1);  // Degenerate fallback

    float2 rayDirUV;
    rayDirUV.x = (g11 * b0 - g01 * b1) / det;
    rayDirUV.y = (g00 * b1 - g01 * b0) / det;
    return rayDirUV;
}
```

**V18 Changes to `findExitEdge()`**:

- Parameter changed from `grad` to `rayDirUV`
- Removed all tangent computation and flipping logic
- Use rayDirUV directly:
  - rayDirUV.x > 0 → prefer RIGHT over LEFT
  - rayDirUV.x < 0 → prefer LEFT over RIGHT
  - rayDirUV.y > 0 → prefer TOP over BOTTOM
  - rayDirUV.y < 0 → prefer BOTTOM over TOP

**Call Site Update** (`texelMarchWithPsi()` lines 1625-1630):

```slang
// V18: Use ray direction projected into UV space for exit selection
float2 rayDirUV = computeRayDirUV(tri, rayD);

// Find exit edge using ray direction in UV space
int exitEdge = findExitEdge(psi00, psi10, psi01, psi11, entryEdge, rayDirUV);
```

**Testing**: Build successful. Awaiting visual verification.

**Expected Result**:

- rayDirUV is view-consistent (same direction from all camera angles)
- All edges (a, b, c, d) should render correctly
- The strip tearing should be completely eliminated

![1764477995429](image/RMIP_texel_log/1764477995429.png)

![1764478033785](image/RMIP_texel_log/1764478033785.png)

![1764478044524](image/RMIP_texel_log/1764478044524.png)

![1764478056699](image/RMIP_texel_log/1764478056699.png)

![1764478070037](image/RMIP_texel_log/1764478070037.png)

![1764478081830](image/RMIP_texel_log/1764478081830.png)

![1764478092623](image/RMIP_texel_log/1764478092623.png)

![1764478107393](image/RMIP_texel_log/1764478107393.png)

**Result**: FAILED - Same behavior as V16/V17!

The rayDirUV approach didn't work because **rayDirUV is NOT the direction along the ψ=0 curve**.
The ψ=0 curve is a different geometric entity - it's not aligned with the ray's UV projection.

---

### Version 19: Explicit Curve Direction Tracking (Nov 29, 2025)

**Key Insight**:

V16-V18 all failed because they tried to determine curve direction from a single measurement:

- V16: gradient tangent (arbitrary direction)
- V17: gradient tangent + entry edge flip (wrong relationship)
- V18: rayDirUV (not the same as curve direction!)

The ψ=0 curve has its OWN direction, independent of how the ray moves across the surface.
We need to TRACK this direction explicitly as we march along the curve.

**New Approach**: Track `curveDir` explicitly throughout the marching loop

1. Initialize `curveDir` from gradient at first texel (aligned with rayDirUV as initial guess)
2. At each texel, use `curveDir` to select exit edge
3. After moving to next texel, update `curveDir` from gradient at new position
4. Ensure consistency: flip tangent if it opposes current curveDir

This maintains a CONTINUOUS direction along the ψ=0 curve!

**V19 Initialization** (before loop):

```slang
// Initialize curve direction from gradient at entry point
float2 curveDir = computeRayDirUV(tri, rayD);  // Initial guess

// Refine from ψ gradient at entry texel center
float2 initUV = (float2(currentTexel) + 0.5) / float2(texSize);
float2 initBary;
texToBary(tri, initUV, initBary);
float2 grad = psiGrad(tri, initBary, rayO, rayD);
float2 tangent = float2(-grad.y, grad.x);

// Align tangent with initial guess
if (dot(tangent, curveDir) < 0)
    tangent = -tangent;

if (length(tangent) > 1e-6)
    curveDir = normalize(tangent);
```

**V19 Update** (after each step):

```slang
// Update curveDir from gradient at new texel center
float2 nextUV = (float2(currentTexel) + 0.5) / float2(texSize);
float2 nextBary;
texToBary(tri, nextUV, nextBary);
float2 grad = psiGrad(tri, nextBary, rayO, rayD);
float2 tangent = float2(-grad.y, grad.x);

// Maintain consistency with previous curveDir
if (dot(tangent, curveDir) < 0)
    tangent = -tangent;

if (length(tangent) > 1e-6)
    curveDir = normalize(tangent);
```

**Testing**: Build successful. Awaiting visual verification.

**Expected Result**:

- curveDir maintains consistent direction along the ψ=0 curve
- No more arbitrary direction flips between texels
- All edges (a, b, c, d) should render correctly

**Result**: FAILED - Still exact same behavior!

Tracking curveDir explicitly didn't help. The initial direction choice (aligned with rayDirUV)
determines the outcome, and once wrong, it stays wrong throughout the march.

---

### Version 20: Simple Exit Selection (2 Crossings = No Direction Needed) (Nov 29, 2025)

**Key Insight**:

V16-V19 all tried to determine curve direction - ALL FAILED.

But wait - in the **common case** where `numCrossings == 2`, we DON'T NEED direction at all!

- One crossing is the entry edge (we know this)
- The other crossing must be the exit edge
- Simple: return the crossing edge that's NOT the entry

Direction is ONLY needed when:

1. First texel (`entryEdge == EDGE_NONE`) - don't know which is entry/exit
2. Multiple crossings (`numCrossings >= 3`) - curve loops or turns sharply

**V20 Fix** - Add simple case BEFORE direction logic:

```slang
// V20 FIX: When numCrossings == 2 and we know the entry, exit is the OTHER crossing
if (numCrossings == 2 && entryEdge != EDGE_NONE)
{
    // Simple: return the crossing edge that's not the entry
    if (crossLeft && entryEdge != EDGE_LEFT) return EDGE_LEFT;
    if (crossRight && entryEdge != EDGE_RIGHT) return EDGE_RIGHT;
    if (crossBottom && entryEdge != EDGE_BOTTOM) return EDGE_BOTTOM;
    if (crossTop && entryEdge != EDGE_TOP) return EDGE_TOP;
}

// Only use direction for: first texel or 3+ crossings
// ... existing curveDir logic ...
```

**Testing**: Build successful. Awaiting visual verification.

**Expected Result**:

- The common case (2 crossings) is now handled simply without direction
- Direction only affects first texel or rare 3+ crossing cases
- Should dramatically reduce direction-related errors

**Result**: FAILED - Still exact same behavior!

---

## Deep Analysis: Why V12-V20 All Failed (Nov 30, 2025)

After careful analysis of the RMIP paper, screenshots from V15/V18, and the implementation history, the root cause of the persistent stripping bug is now clear.

### The Core Problem: ψ-Guided Texel Marching is Fundamentally Unreliable

The stripping artifacts **ARE the ψ=0 isolines** rendered on the surface. The marching fails exactly where ψ≈0, creating visible strips that follow the mathematical ψ=0 curve.

### Three Fundamental Issues

#### Issue 1: Wrong Entry Texel Detection

Current code (lines 1496-1516):

```slang
float3 Q_entry = rayO + rayTMin * rayD;  // 3D AABB entry point
float2 entryBary;
bool validEntry = inverseDisplacement(tri, Q_entry, entryBary);
currentTexel = int2(floor(entryUV * float2(texSize)));
```

**The Problem**: `rayTMin` comes from the ray-AABB intersection, NOT where the ψ=0 curve enters the UV region. The inverse displacement of the AABB entry point gives a UV coordinate that may be far from where the actual ψ=0 curve enters.

**Correct approach**: Find where ψ=0 curve intersects the UV region boundary (paper Section 4.4), not where the 3D ray enters the AABB.

#### Issue 2: ψ Sign Detection Fails Near ψ≈0

The sign-based crossing detection:

```slang
bool crossLeft = (psi00 * psi01 < 0.0);  // Sign change on left edge
```

**The Problem**: Near the ψ=0 curve, both corners have ψ values very close to zero. Due to floating-point precision:

- `psi00 = 1e-8`, `psi01 = -1e-8` → `crossLeft = true`
- `psi00 = 1e-8`, `psi01 = 1e-9` → `crossLeft = false` (same side of curve, different result!)

This causes:

- `numCrossings == 0`: Curve passes through texel but no sign change detected → `EDGE_NONE` → fallback path
- `numCrossings == 3 or 4`: Multiple edges appear to have crossings → wrong exit selection

#### Issue 3: Fallback Direction is Asymmetric

When `exitEdge == EDGE_NONE` (lines 1652-1663):

```slang
if (exitEdge == EDGE_NONE) {
    if (currentTexel.x < texelMax.x)
        currentTexel.x++;      // Always try +X first
    else if (currentTexel.y < texelMax.y)
        currentTexel.y++;      // Then +Y
    else
        break;
}
```

**The Problem**: This fallback ONLY marches in +X and +Y directions, NEVER in -X or -Y. When the ψ=0 curve moves in the -X or -Y direction, the fallback fails to follow it, creating the strips.

### Why Each Version Failed

| Version | Approach                     | Why It Failed                                                                                |
| ------- | ---------------------------- | -------------------------------------------------------------------------------------------- |
| V12     | Initial ψ-guided            | All three fundamental issues present                                                         |
| V13     | ψ degeneracy + tessellation | tessellateUVRegion() capped at 8×8, also broken                                             |
| V14     | Brute force bypass           | Proved bd-edge tearing NOT caused by ψ degeneracy (correct diagnosis, but fix was disabled) |
| V15     | Unclamped ψ values          | Correct fix for one symptom, doesn't fix fundamentals                                        |
| V16     | Gradient tangent direction   | Arbitrary initial direction, problem rotates but doesn't disappear                           |
| V17     | Entry-consistent flip        | Wrong assumption: entry position ≠ curve entry point                                        |
| V18     | rayDirUV direction           | Ray direction in UV ≠ ψ=0 curve direction                                                  |
| V19     | Tracked curveDir             | Initial direction wrong → error propagates                                                  |
| V20     | Simple 2-crossing case       | Entry texel still wrong, sign detection still unreliable                                     |

### The Strips Pattern Explained

Looking at the screenshots:

- **V15 edge a (clean)**: ψ values clearly positive or negative at corners → correct crossings detected
- **V15 edge b (strips)**: ψ≈0 at some corners → crossing detection fails → fallback (+X only) misses texels
- **V18 strips**: Same pattern - strips align with where ψ passes through or very near corner positions

The strips are NOT random - they follow the mathematical ψ=0 isolines projected onto the surface.

### The Correct Fix: Abandon ψ-Guided Marching for Leaf Nodes

The hierarchical RMIP traversal already narrows down to small UV regions (typically 2-8 texels wide). At this point, ψ-guided marching adds complexity with unreliable benefits.

**V21 Fix**: Replace ψ-guided marching with **brute-force texel iteration** at leaf level:

1. The hierarchical traversal gets us to a small UV region
2. At leaf level, simply iterate ALL texels in that region
3. Test each texel's micro-triangles for intersection
4. Return the closest hit

This is:

- **More robust**: No ψ sign detection issues
- **Simpler**: No entry/exit edge logic needed
- **Still efficient**: Only testing texels in the small leaf region (not the entire texture)
- **Guaranteed correct**: Every texel in the region is tested

---

### Version 21: Brute-Force Leaf Texel Iteration (Nov 30, 2025)

**Key Insight from Analysis**:

All V12-V20 failures stem from trying to be clever about which texels to visit. The ψ-guided marching is mathematically elegant but practically unreliable due to:

1. Wrong entry texel detection (using AABB entry, not ψ=0 curve entry)
2. Numerical precision issues near ψ≈0
3. Asymmetric fallback that only marches +X/+Y

**V21 Solution**: At leaf level, simply test ALL texels in the small region. The hierarchical RMIP already narrows us to typically 4-16 texels. Testing all is cheap and guaranteed correct.

**Changes**:

1. Replace `texelMarchWithPsi()` with `testAllTexelsInRegion()`
2. Simple double loop over all texels in [texelMin, texelMax]
3. Test each texel's 2 micro-triangles for intersection
4. Track best (closest) hit across all texels
5. No ψ computation, no exit edge logic, no fallback paths

**V21 Code** (key section):

```slang
// V21: Simple double loop over ALL texels - no ψ, no marching, just test everything
for (int ty = texelMin.y; ty <= texelMax.y; ty++)
{
    for (int tx = texelMin.x; tx <= texelMax.x; tx++)
    {
        int2 currentTexel = int2(tx, ty);

        // ... compute texel corners, convert to barycentric ...

        // Test both micro-triangles for intersection
        // Track closest hit across all texels
    }
}
```

**Why This Should Work**:

1. **No entry detection needed**: We test ALL texels, so we don't need to know where ψ=0 enters
2. **No ψ sign issues**: We don't compute ψ at all, eliminating precision problems
3. **No direction bias**: We test +X, -X, +Y, -Y equally via the double loop
4. **Still efficient**: The hierarchical RMIP traversal narrows to small regions (typically 4-16 texels) before reaching leaf level

**Testing**: Awaiting build and visual verification.

**Expected Result**:

- The stripping artifacts should be completely eliminated
- Every texel in the leaf region is tested, so no ray can "slip through the cracks"
- Performance may be slightly lower than optimal ψ-guided marching, but correctness is guaranteed

**Result**:

![1764480455742](image/RMIP_texel_log/1764480455742.png)

![1764480477780](image/RMIP_texel_log/1764480477780.png)

![1764480496932](image/RMIP_texel_log/1764480496932.png)

![1764480529591](image/RMIP_texel_log/1764480529591.png)

**Result**: PARTIAL SUCCESS - Strips eliminated, but grazing angle tearing remains!

The ψ-guided stripping artifacts are **completely gone**. However, a different issue has emerged:

- **Screenshot 1**: Grazing angle rendering correctly - no issues
- **Screenshot 2**: Irregular tearing/holes at certain angle
- **Screenshot 3**: Same good angle as screenshot 1
- **Screenshot 4**: More severe tearing at a different grazing angle

**Key observations**:

1. The tearing is NOT the regular strip pattern from V12-V20 - it's irregular patches
2. Only appears at certain grazing angles, not all
3. Some grazing angles render perfectly fine
4. The pattern is different from the old ψ=0 isoline strips

**Conclusion**: The leaf-level brute-force testing fixed the ψ-guided marching bug. The remaining tearing is a **separate issue** that was likely always present but masked by the more prominent stripping artifacts.

---

### Version 22: Investigating Grazing Angle Tearing (Nov 30, 2025)

**Hypothesis**: The issue is in the **hierarchical traversal**, not the leaf-level testing.

Since V21's brute-force leaf testing works correctly (strips are gone), the problem must be that some UV regions are being **incorrectly rejected** during hierarchical traversal at grazing angles.

**Possible causes**:

1. **AABB bounds too tight**: `computeUVRegionAABB_Affine()` might compute bounds that are too tight at grazing angles, causing valid regions to be rejected by ray-AABB test
2. **Numerical precision in ray-AABB**: At grazing angles, `rayAABBIntersect()` becomes numerically unstable
3. **UV region overlap check**: `uvRegionOverlapsTriangle()` might incorrectly reject valid regions
4. **Inverse displacement failure**: At grazing angles, `inverseDisplacement()` might fail to converge, causing bound reduction to skip valid UV ranges
5. **Initial prism intersection**: The bounding prism might not correctly contain the displaced surface at extreme angles

**Investigation approach**: Add debug visualization to identify which stage is causing the rejection.

**Root Cause Identified**: Initial UV bounds narrowing (lines 1783-1796) excludes valid regions at grazing angles:

1. At grazing angles, `inverseDisplacement()` of prism entry/exit gives small UV range
2. The 10% padding is not enough when ray travels long 3D distance with small UV change
3. Valid intersection regions outside the narrow initial bounds are never pushed to stack

**V22 Fix**: Detect grazing angle and skip UV bound narrowing:

```slang
// V22 FIX: Detect grazing angle and use conservative bounds
float3 triNormal = normalize(cross(tri.dPdu, tri.dPdv));
float cosAngle = abs(dot(rayDir, triNormal));
bool isGrazingAngle = cosAngle < 0.3;  // ~73 degrees from normal

if (validEntry && validExit && !isGrazingAngle)
{
    // Narrow bounds only for non-grazing angles
    // ... existing bound narrowing code ...
}
// else: Use full triangle UV bounds (conservative but correct)
```

**Testing**: Awaiting build and visual verification.

**Expected Result**:

- Grazing angle tearing should be eliminated
- Performance slightly lower at grazing angles (more UV regions to test)
- Non-grazing angles unchanged (still use optimized narrow bounds)

**Result**: FAILED - Made things much worse!

![1764480975169](image/RMIP_texel_log/1764480975169.png)

The grazing angle detection caused massive tearing at ALL grazing angles instead of just some. This approach is fundamentally wrong - a correct algorithm should work at all viewing angles without special-casing.

**Reverted to V21** via git restore.

---

### Version 22: Proper Investigation of Grazing Angle Tearing (Nov 30, 2025)

**Lesson learned**: Don't try to work around bugs with angle-based heuristics. Find and fix the actual bug.

**Re-reading the paper (Section 4)**: The paper describes:

1. Prism intersection gives initial 3D interval
2. Inverse displacement projects endpoints to UV (guaranteed to converge inside prism)
3. Turning points split the UV curve into monotonic segments
4. Hierarchical traversal with bound reduction via inverse displacement
5. Texel marching at leaf level

**Key insight from paper (Section 4.1, Fig 4)**:

> "The key advantage of using a prism as a 3D bounding primitive over a simple axis-aligned box is that it is fully contained inside the convergence region, providing the guarantee that all our projections will fall inside the base triangle."

**Investigating potential causes**:

1. **Ray-AABB intersection precision at grazing angles**: When ray nearly parallel to AABB face, `tEntry ≈ tExit` can cause incorrect rejection
2. **Bound reduction discarding valid regions**: After ray-AABB test, we project intersection points back to UV and reduce bounds - this might exclude valid regions
3. **Stack overflow or iteration limit**: Maybe we're hitting MAX_TRAVERSAL_ITERS or MAX_STACK_SIZE at grazing angles
4. **Affine arithmetic bounds too tight**: The AABB computed from affine arithmetic might be too tight and miss the actual surface

**ROOT CAUSE IDENTIFIED** (after code analysis):

Looking at lines 1877-1882, we project ray-AABB intersection points (`Q_entry_region`, `Q_exit_region`) to UV space using inverse displacement. But the paper (Section 4.1, Fig 4) explicitly states:

> "Not all 3D points can be successfully projected; however, we only deal with points located inside a prism around the triangle, and these are guaranteed to fall inside the triangle."

**The problem**: The AABB (computed from affine arithmetic + padding) can extend OUTSIDE the bounding prism. When the ray-AABB intersection points are outside the prism:

1. `inverseDisplacement()` might still converge (return `true`)
2. But the projected UV coordinates are INCORRECT
3. The bound reduction uses these incorrect UV to narrow the search region
4. Valid texels outside the (incorrectly) reduced region are never tested → tearing

This explains why:

- Only some grazing angles have tearing (depends on whether ray-AABB intersection is inside/outside prism)
- The tearing is irregular (depends on specific ray-triangle-AABB configuration)
- V21's brute-force leaf testing fixed strips but not this (the issue is in hierarchical traversal)

**V22 Fix**: Disable bound reduction entirely. Rely only on subdivision.

The paper (Section 4.3, Fig 5) mentions bound reduction is OPTIONAL:

> "Bound tightening via interval projection is beneficial only for some rays. We need explicit subdivision to guarantee that bounds eventually shrink."

Disabling bound reduction will be slightly slower but guaranteed correct.

**V22 Code Change**: Removed the entire bound reduction block (lines 1872-1930), replaced with comment explaining why.

```slang
// V22 FIX: Bound reduction DISABLED
//
// The bound reduction via inverse displacement (Paper line 15) was
// causing grazing angle tearing. The issue: ray-AABB intersection
// points can be OUTSIDE the bounding prism, where inverse displacement
// is not guaranteed to converge correctly.
//
// Disabling bound reduction is slightly slower but guaranteed correct.
// The subdivision alone is sufficient to narrow bounds to leaf level.
```

**Testing**: Awaiting build and visual verification.

**Expected Result**:

- Grazing angle tearing should be eliminated
- All angles should render correctly
- Performance slightly lower (more subdivision iterations needed)

**Result**: FAILED - Much worse tearing than V21!

![1764481554938](image/RMIP_texel_log/1764481554938.png)

![1764481573769](image/RMIP_texel_log/1764481573769.png)

**Analysis**: Disabling bound reduction entirely made things significantly worse:

- Tearing now happens at almost all angles (not just some grazing angles)
- Only near-vertical viewing angles render correctly
- The algorithm hits iteration limits without bound reduction

**Root Cause**: Without bound reduction, pure subdivision takes too many iterations to reach leaf level:

- MAX_TRAVERSAL_ITERS = 128 is not enough
- MAX_STACK_SIZE = 32 is not enough
- The algorithm needs bound reduction to converge efficiently

**Conclusion**: Bound reduction is NECESSARY for the algorithm to work. We can't simply disable it.
The fix should be to make bound reduction SAFE, not to remove it entirely.

---

### Version 23: Safe Bound Reduction with Validation (Nov 30, 2025)

**Archive**: `displacement_intersection_v22.slang`

**Key Insight**: The problem is not bound reduction itself, but that ray-AABB intersection
points can be OUTSIDE the bounding prism, where `inverseDisplacement()` gives incorrect results.

**Paper Reference (Section 4.1, Fig 4)**:

> "Not all 3D points can be successfully projected; however, we only deal with points
> located inside a prism around the triangle, and these are guaranteed to fall inside
> the triangle."

**V23 Solution**: Keep bound reduction, but VALIDATE the inverse displacement results:

1. After `inverseDisplacement(Q)` returns (u,v), check if the projection is valid
2. Validation: Compute `P(u,v) + t*N(u,v) = Q` to find t (signed distance along normal)
3. If `t` is within reasonable bounds (related to hMin, hMax), the projection is valid
4. If validation fails, SKIP bound reduction for this iteration (use subdivision only)

**Why this works**:

- Valid projections (inside prism) give correct UV → bound reduction helps
- Invalid projections (outside prism) are detected → bound reduction skipped
- Subdivision still guarantees bounds shrink → algorithm eventually converges

**Code Changes** (lines 1872-1930):

```slang
// V23: Safe bound reduction with validation
// Project entry/exit points and VALIDATE results before applying

float3 Q_entry = rayOrigin + rayDir * regionTEntry;
float3 Q_exit = rayOrigin + rayDir * regionTExit;

float2 projEntry, projExit;
bool entryValid = inverseDisplacement(tri, Q_entry, projEntry);
bool exitValid = inverseDisplacement(tri, Q_exit, projExit);

// V23 VALIDATION: Check that projected points are actually close to Q
// If the inverse displacement "worked" but gave wrong UV, the 3D reconstruction
// will be far from the original point
if (entryValid)
{
    float3 P_entry = getP(tri, projEntry);
    float3 N_entry = getN(tri, projEntry);
    float t_entry = dot(Q_entry - P_entry, normalize(N_entry));
    // If t is way outside displacement range, projection is invalid
    if (t_entry < hMin - 0.1 || t_entry > hMax + 0.1)
        entryValid = false;
}

if (exitValid)
{
    float3 P_exit = getP(tri, projExit);
    float3 N_exit = getN(tri, projExit);
    float t_exit = dot(Q_exit - P_exit, normalize(N_exit));
    if (t_exit < hMin - 0.1 || t_exit > hMax + 0.1)
        exitValid = false;
}

// Only apply bound reduction if BOTH projections are valid
if (entryValid && exitValid)
{
    float2 projUVMin = min(baryToTex(tri, projEntry), baryToTex(tri, projExit));
    float2 projUVMax = max(baryToTex(tri, projEntry), baryToTex(tri, projExit));

    // Add small padding for safety
    float2 padding = (bound.uvMax - bound.uvMin) * 0.05;
    projUVMin -= padding;
    projUVMax += padding;

    // Reduce bounds (intersection with current bounds)
    bound.uvMin = max(bound.uvMin, projUVMin);
    bound.uvMax = min(bound.uvMax, projUVMax);
}
// If validation failed, skip bound reduction - subdivision will still shrink bounds
```

**Build Status**: ✅ Compiled successfully

**Testing**: Awaiting visual verification. Please test at various viewing angles, especially grazing angles that showed tearing in V21/V22.

**Expected Results**:

- Grazing angle tearing should be eliminated (validation catches invalid projections)
- Vertical/normal viewing angles should still work (bound reduction helps convergence)
- Performance should be similar to V21 (bound reduction still applied when valid)

**Testing Result**: Same as V21 - validation did NOT fix the tearing

![1764482188226](image/RMIP_texel_log/1764482188226.png)

![1764482193708](image/RMIP_texel_log/1764482193708.png)

**Critical New Observation**:

- Tearing ONLY appears when viewing direction is close to the **DIAGONAL** of the plane
- Viewing from the **EDGES** (not diagonal) has NO tearing at ANY grazing angle
- This is true for both V21 and V23

**Analysis**: The diagonal is where **triangles meet**! A quad mesh is split into two triangles
along the diagonal. The tearing pattern follows the triangle seams/boundaries.

This suggests the root cause is NOT:

- ❌ Inverse displacement failure (would affect all grazing angles)
- ❌ Bound reduction issues (V23 validation didn't help)
- ❌ Iteration limits (would affect all angles equally)

The root cause IS likely:

- ✅ **Triangle boundary handling** - rays near the diagonal edge between triangles
- ✅ **UV space discontinuity** - adjacent triangles may have different UV orientations
- ✅ **Barycentric clipping at edges** - rays at triangle edges might be incorrectly rejected

---

### Version 24: Investigating Triangle Boundary Issue (Nov 30, 2025)

**Archive**: `displacement_intersection_v23.slang`

**Key Insight**: The tearing follows the DIAGONAL of quads, which is exactly where triangles
are split. This is NOT a general grazing angle problem - it's a **triangle seam** problem.

**Hypothesis**: When the ray is nearly parallel to a triangle edge (the diagonal):

1. The ray might "slip between" two adjacent triangles
2. Each triangle's AABB/prism might not fully cover the seam region
3. The barycentric coordinate test `baryInTriangle()` might reject valid hits near edges

**Investigation needed**:

1. Check how `baryInTriangle()` handles points exactly on the edge (u=0, v=0, or u+v=1)
2. Check if adjacent triangles share the same UV at the boundary
3. Look for gaps in coverage when two triangle prisms meet at the diagonal

**V24 Implementation**: Increased barycentric tolerance from 0.01 to 0.05 (BARY_EPS)

The hypothesis is that the diagonal edge (u+v=1) experiences more numerical precision issues
than the u=0 or v=0 edges because:
- The diagonal spans the entire hypotenuse (longer edge)
- More texels straddle the diagonal than the other edges
- The tolerance of 0.01 might not be enough for edge cases

**Code Changes**:
1. Added `static const float BARY_EPS = 0.05;` (was 0.01 scattered throughout)
2. Updated `uvRegionOverlapsTriangle()` to use BARY_EPS
3. Updated `testAllTexelsInRegion()` corner validity check to use BARY_EPS
4. Updated micro-triangle 2 validity check (w11 >= -BARY_EPS)
5. Updated `addSampleToAABB()` to use BARY_EPS

**Build Status**: ✅ Compiled successfully

**Testing**: Awaiting visual verification at diagonal viewing angles.
