# RMIP: Displacement Ray-Tracing via Inversion and Oblong Bounding
## Detailed Technical Analysis

**Paper**: RMIP: Displacement ray-tracing via inversion and oblong bounding
**Authors**: Théo Thonat, Iliyan Georgiev, François Beaune, Tamy Boubekeur (Adobe)
**Published**: SIGGRAPH Asia 2023 Conference Papers
**DOI**: https://doi.org/10.1145/3610548.3618182
**Analysis Date**: November 2025
**Analysis For**: MatForge Project (CIS 5650 Final Project)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Understanding Displacement Mapping](#understanding-displacement-mapping)
3. [Historical Context: Previous Approaches](#historical-context-previous-approaches)
4. [The RMIP Innovation](#the-rmip-innovation)
5. [Technical Deep-Dive](#technical-deep-dive)
6. [glTF and Displacement Maps](#gltf-and-displacement-maps)
7. [Implementation Strategy](#implementation-strategy)
8. [Performance Analysis](#performance-analysis)
9. [Limitations and Considerations](#limitations-and-considerations)
10. [References for Implementation](#references-for-implementation)

---

## Executive Summary

### What Problem Does RMIP Solve?

**The Core Challenge**: How do you efficiently ray-trace highly detailed displaced surfaces without pre-tessellating them into millions of triangles?

**Current Dilemma**:
- **Option 1**: Pre-tessellation → 500MB+ memory for single 4K displacement map, tessellation artifacts
- **Option 2**: Tessellation-Free Displacement Mapping (TFDM) → Accurate but slow (10-15× slower than desired)

**RMIP Solution**: A novel data structure that enables **11× faster** ray tracing than TFDM while consuming **3× less memory** than tessellation, maintaining **full geometric accuracy**.

### Key Innovation in One Sentence

RMIP uses **inverse displacement mapping** to project rays into 2D texture space, then **ping-pongs** between 2D rectangular bounds and 3D object-space bounds to hierarchically narrow down ray-surface intersections, avoiding explicit geometry generation until the final texel-level step.

---

## Understanding Displacement Mapping

### What is Displacement Mapping?

**Definition**: A technique to add geometric detail to a 3D surface by offsetting vertices along their normals according to values stored in a 2D texture (displacement map).

**Conceptually**:
```
Base Surface + Displacement Map → Displaced Surface

For each point P on base surface:
    DisplacedPoint = P + displacement_value * normal_direction
```

### Visual Example

```
Base Triangle (3 vertices)     Displacement Map (4K texture)
      /\                             [height values]
     /  \                            0.0 to 1.0
    /____\

↓ Displacement Applied ↓

Displaced Surface (millions of micro-features)
   /\/\/\/\
  /\/\/\/\/\
 /\/\/\/\/\/\
/____________\
```

### Why Use Displacement Mapping?

**Advantages**:
1. **Compact Storage**: 4K displacement map (~16MB) vs. tessellated mesh (~500MB+)
2. **Resolution Independence**: Can be sampled at any detail level
3. **Easy Authoring**: Artists work with 2D textures (familiar workflow)
4. **Tileable**: Can repeat displacement patterns efficiently
5. **Dynamic**: Can swap/modify displacement maps at runtime

**Use Cases**:
- **Architecture**: Brick walls, stone surfaces, roof tiles
- **Organic**: Skin pores, tree bark, terrain
- **Industrial**: Hammered metal, machined surfaces, fabric weave
- **VFX**: High-resolution creature skin, weathered materials

### Displacement vs. Normal Mapping

| Aspect | Normal Mapping | Displacement Mapping |
|--------|---------------|---------------------|
| **Geometry** | Fake (lighting only) | Real (actual geometry) |
| **Silhouettes** | Incorrect (flat edges) | Correct (displaced edges) |
| **Self-occlusion** | Fake (parallax tricks) | Real (ray tracing) |
| **Shadows** | Incorrect | Correct |
| **Performance** | Fast (texture lookup) | Expensive (geometry) |
| **Memory** | Low | High (if tessellated) |

**Key Insight**: Normal maps are a **visual approximation**. Displacement maps create **real geometry** that interacts correctly with lighting, shadows, and occlusion.

---

## Historical Context: Previous Approaches

### Traditional Approach: Pre-Tessellation (2000s-2020s)

**How It Works**:
1. Pre-process: Subdivide base triangle into millions of micro-triangles
2. Displace each micro-triangle vertex according to displacement map
3. Build acceleration structure (BVH) over all micro-triangles
4. Ray trace normally (hardware-accelerated)

**Example**:
```
Base mesh: 10,000 triangles
4K displacement map → Tessellate to 1024×1024 per triangle
Result: 10 billion triangles
Memory: ~500GB (impractical!)

Practical compromise: Tessellate to 256×256
Result: 650 million triangles
Memory: ~30GB (still huge)
Quality: Visible undersampling artifacts
```

**Problems** (from paper Section 1):
1. **Memory Explosion**: Quadratic growth with resolution
2. **Tessellation Artifacts**: Fixed subdivision misses high-frequency details
3. **Static Geometry**: Cannot dynamically change displacement
4. **Tiling Issues**: Hard to tile displacement maps (seam artifacts in BVH)

**Performance from Paper Table 1**:
- Pre-tessellation memory: **30-235× more** than RMIP
- Pre-tessellation speed: **40-1151× slower** than RMIP
- Reason: BVH construction and traversal overhead for billions of triangles

### Rasterization-Era Techniques (2001-2015)

**For completeness**, these techniques don't apply to ray tracing but show the evolution:

1. **Parallax Mapping** (Kaneko 2001): Offset texture coordinates based on view angle
   - Fast but view-dependent (breaks in ray tracing)

2. **Relief Mapping** (Policarpo 2005): Ray-march through height field
   - More accurate but still view-dependent

3. **Cone Step Mapping** (Dummer 2006): Use precomputed safe distances
   - Faster marching but limited to height fields

**Why These Don't Work for Ray Tracing**: They assume a locally flat tangent space and a fixed view direction. Ray tracing requires handling arbitrary ray directions and curved base surfaces.

### GPU Offline Rendering: Reyes Architecture (2000s)

**Approach**: Lazy tessellation + caching + ray reordering

**How It Works** (Christensen 2003, Hanika 2010):
1. Build two-level acceleration structure (top: coarse, bottom: fine)
2. Only tessellate geometry when rays hit bounding regions
3. Cache tessellated geometry for reuse
4. Reorder rays to maximize cache hits

**Problems**:
- **Ray Coherence Dependency**: Terrible performance if rays scatter (global illumination)
- **Cache Thrashing**: Limited GPU memory for cache
- **Complex Logic**: Cache management overhead
- **Still Tessellates**: Just defers it, doesn't eliminate it

### Breakthrough: Tessellation-Free Displacement Mapping (TFDM) (2021)

**Paper**: Thonat et al., "Tessellation-Free Displacement Mapping for Ray Tracing", SIGGRAPH 2021

**Key Innovation**: Use a **min-max mipmap** as an implicit acceleration structure in texture space.

**How It Works**:
1. Pre-process: Build min-max mipmap of displacement map
   - Each MIP level stores minimum and maximum displacement in that region

2. Ray intersection:
   - Traverse quad-tree in texture space (mipmap hierarchy)
   - For each quad-tree node:
     - Compute 3D bounding box using min/max displacement
     - Test ray against box
     - If hit, descend to children (smaller texture region)
   - Final level: Generate micro-triangle, test intersection

**Advantages**:
- ✅ **Full Accuracy**: No tessellation artifacts
- ✅ **Low Memory**: Only stores mipmap (~2× texture size)
- ✅ **Dynamic**: Can change displacement at runtime
- ✅ **Tileable**: Handles tiled displacement naturally

**Problems** (from RMIP paper Section 1):
1. **Fixed Hierarchy**: Quad-tree structure doesn't adapt to ray
2. **Square Regions Only**: Mipmap nodes are squares, but ray projections are often elongated rectangles
3. **Loose Bounds**: Affine arithmetic produces conservative (loose) 3D bounds
4. **Long Traversals**: Often requires 100-200+ node visits per ray

**Performance**:
- TFDM: 27-606 ms per frame (1080p, various scenes)
- Still **10-20× slower** than desired real-time performance

**This is where RMIP enters the picture.**

---

## The RMIP Innovation

### Core Insight: Ping-Pong Between 2D and 3D

**Observation**: Each space has unique information that can tighten bounds in the other space:

**2D Texture Space**:
- Knows displacement values (min/max height)
- Can provide tight scalar bounds for any rectangular region

**3D Object Space**:
- Knows ray-geometry intersection intervals
- Can provide tight 3D bounding boxes

**RMIP Ping-Pong** (Figure 3 from paper):
```
Start with initial ray-prism intersection (3D)
    ↓
Project to texture space (3D → 2D)
    ↓
Query RMIP for displacement bounds (2D)
    ↓
Compute 3D box from displacement bounds (2D → 3D)
    ↓
Intersect ray with 3D box
    ↓
Project intersection interval back to 2D (3D → 2D)
    ↓
Subdivide 2D rectangular region
    ↓
Repeat (ping-pong continues...)
```

**Why This Is Powerful**: Each iteration tightens the bounds in **both** spaces simultaneously. Typically reduces search region by 50-75% per iteration.

### Novel Component 1: Inverse Displacement Mapping

**Problem**: Given a 3D point in object space, what are its (u,v) texture coordinates?

**Mathematical Formulation** (Equation 2):
```
Forward mapping (known):
S(u,v) = P(u,v) + h(u,v) * N(u,v) / ||N(u,v)||

where:
- P(u,v) = base triangle position (linear interpolation)
- N(u,v) = displacement normal (linear interpolation)
- h(u,v) = displacement height (from texture)

Inverse mapping (need to solve):
Given 3D point O + tD (ray at distance t), find (u,v) such that:
(P(u,v) - (O + tD)) × N(u,v) = 0
```

**Solution** (Section 4.1): Iterative Newton-based numerical inversion
- Input: 3D point (from ray-box intersection)
- Output: (u,v) texture coordinates
- Cost: ~3-5 iterations (Figure 4)
- Guarantee: Always converges inside bounding prism

**Why Previous Work Couldn't Do This**:
- Patterson et al. (1991): Only worked for analytical surfaces (spheres, cylinders)
- Jeschke et al. (2007): Derived cubic equation, but unstable for triangle meshes
- **RMIP**: Numerical approach is both faster and more robust

### Novel Component 2: Rectangular Min-Max Image Pyramid (RMIP)

**Problem**: Need displacement bounds for **arbitrarily shaped rectangles** in texture space, not just squares.

**Why Squares Aren't Enough**:
- Ray projections in texture space are elongated (anisotropic)
- Example: Grazing-angle ray → thin, long rectangle (aspect ratio 1:100)
- Square mipmap: Must use large square to cover → loose bounds → slow traversal

**RMIP Data Structure** (Section 5):

**Core Idea**: Precompute min/max displacement for all rectangles with power-of-two side lengths.

**Query**: Rectangle with arbitrary size (w,h) and position (x,y)
- Decompose into 4 overlapping power-of-two rectangles
- Return min/max of those 4 queries

**Storage** (Figure 6):
```
For N×N texture:
- Square mipmap: N² (1 + 1/4 + 1/16 + ...) ≈ 1.33 N² pixels
- RMIP (naive): N² (1 + log₂N)² pixels → Too large!
- RMIP (compressed): ~N² pixels (same as mipmap!) → Practical!
```

**Compression Trick** (Section 5, supplemental):
- Observation: Fine-level queries (small rectangles) can use interpolated values
- Store full data only for coarse levels (large rectangles)
- Interpolate for fine levels from coarser data
- Trade-off: Slightly looser bounds at fine levels, but traversal is almost done by then

**Query Complexity**: O(1) - Always 4 texture lookups regardless of rectangle size

**Comparison to Prior Work**:
- Wang et al. (2020): Similar structure but missing key features (tiling, fractional LOD, compression)
- Amir et al. (2007): Theoretical foundation (2D range minimum query), but no GPU implementation

### Novel Component 3: Direct 2D Bound Subdivision

**Problem**: How to subdivide the 2D rectangular bound when descending the hierarchy?

**Previous Approach (Patterson 1991)**:
- Project 3D midpoint of bounding box back to 2D
- Use that point to split the 2D region

**Problem with Previous Approach** (Figure 5b):
- 3D bounds are computed with range arithmetic (conservative/loose)
- Midpoint can project **anywhere** along the ray
- Can get arbitrarily unbalanced splits (90%-10%)
- Unbounded traversal depth!

**RMIP Solution** (Figure 5c): Split directly in 2D
1. Find which side of rectangle is longer (width or height)
2. Compute intersection of projected ray with middle line of that side
3. Split rectangle at that intersection point
4. Result: Always 50% reduction in area per step
5. **Bounded traversal**: At most log₂(texture_size) steps

**Why This Is Better**:
- Guaranteed convergence rate
- Simpler computation (no 3D midpoint projection)
- Better cache behavior (predictable access pattern)

### Novel Component 4: Implicit Ray Projection Form

**Problem**: Need to know where the projected ray curve crosses texture-space regions.

**Solution** (Equation 3): Implicit form of ray projection
```
ψ(u,v) = det(P(u,v) - O, N(u,v), D) = 0

where:
- O = ray origin
- D = ray direction
- P(u,v), N(u,v) = base triangle position and normal
```

**This is a quadric** (polynomial of degree 2) in texture space!

**Useful Properties**:
1. **Zero-crossing detection**: Sign change of ψ indicates ray crosses edge
2. **Splitting**: Can compute exact intersection with splitting lines
3. **Turning points**: Partial derivatives give points where ray changes principal direction
   - ψ_u = 0: Ray turns in u-direction
   - ψ_v = 0: Ray turns in v-direction
   - Need to split at turning points to maintain valid rectangular bounds

**Application** (Section 4.2):
- Find turning points (solve two quadratic equations)
- Split initial ray projection at turning points
- Each segment can be bounded by axis-aligned rectangle

**Typical Result**: 1-4 initial segments (usually 1-2 in practice)

---

## Technical Deep-Dive

### Complete Algorithm Walkthrough

**Algorithm 1** (from paper):

```
function IntersectRMIP(ray, triangle, prism, rmip):
    // 1. Initial Setup: Ray-Prism Intersection
    points = intersect(ray, prism)  // Entry and exit points
    if points.empty():
        return NO_HIT

    // 2. Inverse Mapping: 3D → 2D
    bounds = []
    for p in points:
        uv = inversedisplacement(p, triangle)  // Numerical inversion (Section 4.1)
        bounds.append(uv)

    // 3. Find Turning Points (Section 4.2)
    // Where ray projection changes principal direction
    turning_points = solve_zero_derivative(ray, triangle)
    //   ψ_u(u,v) = 0  (turns in u)
    //   ψ_v(u,v) = 0  (turns in v)

    // 4. Split at Turning Points
    bounds = split(bounds, turning_points)
    // Each segment now monotonic in u and v → can be axis-aligned bounded

    // 5. Hierarchical Traversal (Ping-Pong)
    while bounds is not empty:
        bound = bounds.pop()  // LIFO (depth-first, front-to-back)

        // Check if small enough for texel marching
        if area(bound) < marching_threshold:
            // 6. Texel Marching (Section 4.4)
            for texel in texelmarching(bound):
                hit = intersect_displaced_surface(ray, texel, triangle)
                if hit:
                    return hit  // Front-to-back → first hit is closest
            continue

        // 7. Query RMIP for Displacement Bounds (2D → scalar bounds)
        disp_min, disp_max = rmip.query(bound)

        // 8. Compute 3D Surface Bounds (scalar → 3D)
        box = compute_3D_bounds(triangle, bound, disp_min, disp_max)
        //    Sample triangle corners at bound region
        //    Expand by disp_max * normal
        //    Contract by disp_min * normal

        // 9. Ray-Box Intersection (3D test)
        t_near, t_far = intersect(ray, box)
        if no intersection:
            continue  // Cull this region

        // 10. Tighten 2D Bound (3D → 2D, optional)
        // Project intersection interval endpoints back to 2D
        bound = reduce_bound(bound, t_near, t_far)

        // 11. Subdivide 2D Bound (direct split)
        // Split along longer axis at midpoint
        front_bound, back_bound = split_2D(bound)

        // 12. Push to Stack (back first, so front is processed first)
        bounds.push(back_bound)
        bounds.push(front_bound)

    return NO_HIT
```

### Key Performance Characteristics

**From Paper Results** (Table 1, Figures 9-12):

**Traversal Steps**:
- TFDM: 100-300 node visits per ray (average)
- RMIP: 10-30 node visits per ray (average)
- **Reduction**: 10× fewer traversal steps

**Memory Consumption**:
- Pre-tessellation (uniform): 10-235× more than TFDM
- TFDM: 21-256 MB (depending on resolution)
- RMIP: Same as TFDM for equivalent quality
- RMIP (compressed): 30× less than TFDM for same quality

**Render Time** (GPU, 1080p, RTX 3080):
- Pre-tessellation: 69-1151× slower than RMIP
- TFDM: 2.2-9.2× slower than RMIP
- RMIP: 27-182 ms per frame (achieves interactive rates!)

**Why RMIP Is Faster**:
1. Fewer traversal steps (rectangular queries match ray projections)
2. Better cache locality (predictable texture access pattern)
3. Front-to-back traversal (early termination on first hit)
4. Texel marching (amortizes query overhead)

### Texel Marching Detail (Section 4.4)

**Motivation**: When 2D bound becomes small (~texel-sized), hierarchical traversal overhead dominates.

**Solution**: March directly through texels crossed by ray.

**Algorithm**:
```
for each texel in bound region:
    // Use implicit form to determine ray exit edge
    sign_corners[4] = [ψ(corner) for corner in texel_corners]
    exit_edge = determine_exit_edge(sign_corners)

    // Sample displacement at texel center
    uv_center = texel.center
    disp = sample_displacement(uv_center)

    // Interpolate triangle at texel
    pos_base = interpolate_triangle(triangle, uv_center)
    pos_displaced = pos_base + disp * triangle.normal

    // Generate micro-geometry (planar patch or micro-triangle)
    // Test intersection
    t = ray_plane_intersect(ray, pos_displaced, triangle.normal)
    if valid_hit(t):
        return HIT(t, uv_center)

    // Move to next texel
    texel = texel.neighbor[exit_edge]
```

**Why This Is Efficient**:
1. **Amortizes misalignment**: Rectangle bounds not aligned with texel grid → single texel tested multiple times with hierarchical approach
2. **Compensates for RMIP resolution**: RMIP might be lower-res than displacement map → texel march fills the gap
3. **Simple and fast**: Linear march, no complex queries

**Threshold Choice** (Figure 11):
- Too large: Hierarchical traversal underdeveloped → slow
- Too small: Texel marching not exploited → redundant tests
- Sweet spot: ~4-16 texels per side (depends on RMIP resolution)

---

## glTF and Displacement Maps

### Current glTF 2.0 Support

**Official Status**: glTF 2.0 specification **does not** include displacement mapping as a core feature.

**What glTF 2.0 Has**:
- ✅ **Normal maps** (`normalTexture`): Standard feature
- ✅ **Occlusion maps** (`occlusionTexture`): Standard feature
- ✅ **PBR textures**: Base color, metallic, roughness
- ✅ **Extensions**: 13 KHR extensions for advanced materials
  - `KHR_materials_clearcoat`
  - `KHR_materials_transmission`
  - `KHR_materials_sheen`
  - etc.

**What glTF 2.0 Does NOT Have**:
- ❌ **Displacement maps**: Not in core spec
- ❌ **Height maps**: Not in core spec
- ❌ **Vector displacement**: Not in core spec

### Proposed Extensions (Not Standardized)

**Various proposals exist**, but none are officially adopted:

1. **`KHR_materials_displacement`** (proposed, not ratified):
   ```json
   {
     "materials": [{
       "extensions": {
         "KHR_materials_displacement": {
           "displacementTexture": { "index": 5 },
           "displacementScale": 0.1,
           "displacementBias": 0.0
         }
       }
     }]
   }
   ```

2. **Vendor-specific extensions**:
   - Adobe, Autodesk, and others have internal extensions
   - Not compatible across tools

### Current Industry Practice

**How displacement is currently handled in glTF workflows**:

1. **Bake to normal maps**: Most common approach
   - Displace high-poly mesh
   - Bake to normal map
   - Use normal map in glTF
   - **Loss**: No actual geometry displacement, only lighting approximation

2. **Pre-tessellate**: Export displaced geometry
   - Apply displacement in DCC tool (Blender, Maya, etc.)
   - Export high-poly mesh
   - **Problem**: Large file sizes (100MB+ models)

3. **Custom extensions**: Renderer-specific
   - Unreal Engine: Import displacement as custom data
   - Unity: Material property extensions
   - **Problem**: Not portable

### MatForge Approach: Custom Extension

**Our Strategy**:

Define a **`MATFORGE_displacement`** extension for our project:

```json
{
  "materials": [{
    "name": "Rough Stone",
    "pbrMetallicRoughness": {
      "baseColorTexture": { "index": 0 },
      "metallicFactor": 0.0,
      "roughnessFactor": 0.7
    },
    "normalTexture": { "index": 1 },
    "extensions": {
      "MATFORGE_displacement": {
        "displacementTexture": { "index": 2 },
        "displacementScale": 0.05,
        "displacementBias": 0.0,
        "rmipResolution": 1024,
        "enableRMIP": true
      }
    }
  }]
}
```

**Fields**:
- `displacementTexture`: Index to texture in glTF textures array
- `displacementScale`: Multiplier for displacement values (world-space units)
- `displacementBias`: Offset for displacement values (default 0.0)
- `rmipResolution`: Resolution of RMIP structure (default: texture resolution)
- `enableRMIP`: Toggle RMIP ray tracing (fallback to tessellation if false)

**Implementation Path**:
1. Extend glTF loader to recognize `MATFORGE_displacement`
2. Load displacement texture as standard texture
3. Invoke RMIP builder when extension is present
4. Attach RMIP data to material
5. Use RMIP custom intersection shader for that material

**Fallback Strategy**:
- If extension not recognized: Treat as normal material (no displacement)
- If RMIP build fails: Fallback to parallax occlusion mapping (POM)
- If GPU doesn't support custom intersection shaders: Fallback to pre-tessellation

### Alternative: External Metadata

**Another approach**: Keep displacement data external to glTF

```
materials/
├── rough_stone.gltf              # Standard glTF (no displacement)
├── rough_stone_displacement.png  # Displacement map
└── rough_stone_matforge.json     # MatForge metadata
```

**`rough_stone_matforge.json`**:
```json
{
  "material": "Rough Stone",
  "displacement": {
    "map": "rough_stone_displacement.png",
    "scale": 0.05,
    "bias": 0.0,
    "tiling": [5.0, 5.0]
  },
  "rmip": {
    "resolution": 1024,
    "compression": "medium"
  }
}
```

**Advantages**:
- ✅ Standard glTF (loads in any viewer)
- ✅ MatForge-specific data separate
- ✅ Easy to version control separately

**Disadvantages**:
- ❌ Two files to manage (glTF + metadata)
- ❌ Manual association needed

**Recommendation**: Start with glTF extension, provide export script for external metadata option.

---

## Implementation Strategy

### Phase 1: RMIP Data Structure Builder (Week 1)

**File**: `src/rmip_builder.hpp/cpp`

**Inputs**:
- Displacement texture (loaded via stb_image or similar)
- Desired RMIP resolution (e.g., 1024×1024)

**Process**:
1. Load displacement texture as float array
2. Build power-of-two rectangle hierarchy:
   ```cpp
   for each log_width in 0..log2(N):
       for each log_height in 0..log2(N):
           for each position (x, y):
               compute min/max over rectangle [x, x+2^log_width) × [y, y+2^log_height)
               store in RMIP structure
   ```

3. Apply compression (optional):
   - Keep full resolution for coarse levels (large rectangles)
   - Interpolate fine levels from coarse levels

**Output**:
- RMIP texture (Texture2DArray or structured buffer)
- Per-layer format: RG16F (min in R, max in G)
- Total size: ~N² pixels with compression

**Estimated LOC**: ~200 lines C++

### Phase 2: Inverse Mapping Utilities (Week 1-2)

**File**: `shaders/rmip_common.h.slang`

**Key Functions**:

```slang
// Inverse displacement mapping (Section 4.1)
// Numerically solve: (P(u,v) - worldPos) × N(u,v) = 0
float2 inversedisplacement(float3 worldPos, Triangle tri) {
    // Initial guess: Project to base triangle plane
    float3 bary = barycentric_coords(worldPos, tri);
    float2 uv = interpolate_uv(tri, bary);

    // Newton iteration (3-5 iterations)
    for (int i = 0; i < 5; i++) {
        float3 P = interpolate_position(tri, uv);
        float3 N = interpolate_normal(tri, uv);

        // Residual: r = (P - worldPos) × N
        float3 r = cross(P - worldPos, N);
        if (length(r) < 1e-6)
            break;  // Converged

        // Jacobian and Newton step
        // ... (see paper supplemental for full derivation)
        float2 delta_uv = solve_linear_system(jacobian, r);
        uv -= delta_uv;
    }

    return uv;
}

// Implicit ray projection (Section 4.2)
float ray_projection_implicit(float2 uv, float3 rayOrigin, float3 rayDir, Triangle tri) {
    float3 P = interpolate_position(tri, uv);
    float3 N = interpolate_normal(tri, uv);
    return det3x3(P - rayOrigin, N, rayDir);
}

// Compute 3D bounding box from displacement bounds (Section 4.3)
AABB compute_displaced_bounds(Triangle tri, Rect2D texRect, float dispMin, float dispMax) {
    // Sample triangle corners at texture rectangle corners
    float3 corners[4];
    corners[0] = interpolate_position(tri, texRect.min);
    corners[1] = interpolate_position(tri, float2(texRect.max.x, texRect.min.y));
    corners[2] = interpolate_position(tri, float2(texRect.min.x, texRect.max.y));
    corners[3] = interpolate_position(tri, texRect.max);

    // Compute AABB of base corners
    AABB bounds;
    bounds.min = min(min(corners[0], corners[1]), min(corners[2], corners[3]));
    bounds.max = max(max(corners[0], corners[1]), max(corners[2], corners[3]));

    // Expand by displacement range
    float3 N = tri.normal;  // Could use per-corner normals for tighter bounds
    bounds.min += dispMin * N;
    bounds.max += dispMax * N;

    return bounds;
}
```

**Estimated LOC**: ~300 lines Slang

### Phase 3: Custom Intersection Shader (Week 2)

**File**: `shaders/rmip_intersection.slang`

**Entry Point**:
```slang
[shader("intersection")]
void rmipIntersection() {
    // Get ray and geometry info from built-in variables
    RayDesc ray;
    ray.Origin = ObjectRayOrigin();
    ray.Direction = ObjectRayDirection();
    ray.TMin = RayTMin();
    ray.TMax = RayTMax();

    uint primID = PrimitiveIndex();
    uint instanceID = InstanceID();

    // Load triangle data
    Triangle tri = loadTriangle(primID);

    // Run RMIP traversal (Algorithm 1)
    bool hit = traverse_rmip(ray, tri, instanceID);

    // If hit, ReportHit() was already called in traverse_rmip
}
```

**Estimated LOC**: ~500 lines Slang

### Phase 4: Integration with Path Tracer (Week 2-3)

**Files to Modify**:

1. **`src/renderer_pathtracer.cpp`**: Setup BLAS with AABB geometry
   ```cpp
   if (material.hasDisplacementWithRMIP) {
       geometry.geometryType = VK_GEOMETRY_TYPE_AABBS_KHR;
       // Compute loose AABB for entire triangle + displacement
   }
   ```

2. **`shaders/gltf_pathtrace.slang`**: Handle hit attributes from RMIP
   ```slang
   [shader("closesthit")]
   void rmipClosestHit(inout HitPayload payload, in HitAttributes attr) {
       // attr.uv from RMIP intersection shader
       // Reconstruct hit state with displaced geometry
   }
   ```

3. **`src/renderer.cpp`**: Invoke RMIP builder on scene load
   ```cpp
   void GltfRenderer::createVulkanScene() {
       for (auto& mat : scene.materials) {
           if (mat.hasDisplacement) {
               auto rmipData = m_rmipBuilder.build(mat.displacementTexture);
               m_resources.rmipBuffers.push_back(createRMIPBuffer(rmipData));
           }
       }
   }
   ```

**Estimated LOC**: ~300 lines C++/Slang total

---

## Performance Analysis

### Complexity Analysis

**Pre-processing**:
- **RMIP Build**: O(N² log²N) time, O(N²) space
  - For 4K texture (N=4096): ~1-2 seconds on GPU
  - Amortized if displacement map is reused

**Runtime (per ray intersection)**:
- **Traversal**: O(log N) expected, O(N) worst-case
  - Typical: 10-30 steps for 4K displacement
  - Worst-case: ~40 steps (bounded by direct subdivision)

- **Texel Marching**: O(√N) expected
  - Typical: 5-20 texels per ray
  - Depends on marching threshold

- **RMIP Query**: O(1) - Always 4 texture fetches
  - Optimized with texture cache

**Total Per-Ray Cost**:
- ~20 RMIP queries (10-30 steps × 1 query each)
- ~10 AABB intersection tests
- ~15 texels marched
- ~5 inverse displacement iterations
- **Total**: ~100-200 operations per ray (vs. 1000+ for TFDM)

### Bottleneck Analysis (from Paper Section 6)

**GPU Execution Model**:
- Ray tracing is **divergent**: Each ray can take different number of steps
- SIMD efficiency depends on warp coherence

**RMIP Characteristics**:
1. **Iteration Count Variation**: 10-40 steps per ray (4× range)
   - Impact: Some threads idle while others work
   - Mitigation: Sort rays by traversal depth (future work)

2. **Texture Access Pattern**: Mostly coherent (rectangular queries)
   - Cache hit rate: ~70-80%
   - Better than TFDM (random access): ~40-50%

3. **Numerical Inversion**: Fixed iteration count (5 steps)
   - Good warp coherence
   - But: Expensive operations (dot products, matrix solves)

**Profiling Results** (Figure 11, ablation study):
- RMIP queries: ~40% of time
- Inverse displacement: ~25% of time
- AABB intersection: ~20% of time
- Texel marching: ~15% of time

**Optimization Opportunities**:
1. **Lower RMIP resolution**: 512×512 instead of 4096×4096
   - Impact: ~2× faster queries
   - Trade-off: Slightly looser bounds, more marching

2. **Simplified inversion**: Analytical for flat triangles
   - Impact: ~30% faster on simple geometry
   - Limitation: Only works for nearly-flat base surfaces

3. **Adaptive marching threshold**: Based on displacement frequency
   - Impact: ~10-20% faster on average
   - Complexity: Requires frequency analysis pre-processing

---

## Limitations and Considerations

### Known Limitations (from Paper Section 7)

1. **Moderate Resolution Displacement**:
   - RMIP shines for 2K-4K displacement maps with tiling
   - For 256×256 displacement, pre-tessellation might be simpler
   - **Recommendation**: Use RMIP when displacement resolution × tiling > 1K×1K

2. **Limited Tiling**:
   - For 1×1 tiling, memory advantage is less pronounced
   - **Recommendation**: Best for 4×4+ tiling factors

3. **Static Displacement Content**:
   - Dynamic displacement requires RMIP rebuild (~5ms for 4K)
   - **Recommendation**: For animated displacement, consider caching or LOD

4. **Base Surface Curvature**:
   - Inverse displacement iteration count increases with curvature
   - Flat triangles: ~3 iterations
   - Highly curved: ~8-10 iterations
   - **Recommendation**: Subdivide highly curved base geometry

5. **GPU Architecture Dependency**:
   - Performance varies with cache size and SIMD width
   - Best on RTX 3000+ series (large L2 cache, 32-wide warps)
   - **Consideration**: Test on target hardware early

### Comparison with Other Techniques

| Technique | Memory | Speed | Quality | Dynamic | Tiling |
|-----------|--------|-------|---------|---------|--------|
| **Pre-tessellation** | ❌ Huge | ✅ Fast | ⚠️ Artifacts | ❌ Static | ❌ Hard |
| **Parallax Occlusion** | ✅ Low | ✅ Fast | ❌ Fake | ✅ Yes | ✅ Easy |
| **TFDM (2021)** | ✅ Low | ⚠️ Slow | ✅ Accurate | ✅ Yes | ✅ Easy |
| **RMIP (2023)** | ✅ Low | ✅ Fast | ✅ Accurate | ✅ Yes | ✅ Easy |

**When to Use RMIP**:
- High-resolution displacement (2K+)
- Tiled displacement (4×4+)
- Real-time ray tracing target
- Memory-constrained environment
- Dynamic displacement content

**When NOT to Use RMIP**:
- Low-resolution displacement (256×256) → use pre-tessellation
- Single-view rasterization → use parallax occlusion mapping
- Offline rendering → use full tessellation or subdivision surfaces
- No ray tracing hardware → use rasterization alternatives

---

## References for Implementation

### Primary Source

**RMIP Paper**:
- Thonat et al., "RMIP: Displacement ray-tracing via inversion and oblong bounding", SIGGRAPH Asia 2023
- DOI: 10.1145/3610548.3618182
- **Sections to Focus On**:
  - Section 3: Method overview
  - Section 4: Texture-space traversal (implementation details)
  - Section 5: RMIP structure (data structure)
  - Algorithm 1: Pseudo-code

### Prerequisite Papers

**TFDM (Predecessor)**:
- Thonat et al., "Tessellation-Free Displacement Mapping for Ray Tracing", SIGGRAPH 2021
- Provides context for RMIP improvements

**Inverse Displacement**:
- Patterson et al., "Inverse Displacement Mapping", Computer Graphics Forum 1991
- Logie & Patterson, "Inverse Displacement Mapping in the General Case", 1995

**2D Range Queries**:
- Amir et al., "Two-Dimensional Range Minimum Queries", CPM 2007
- Theoretical foundation for RMIP structure

### Related Work

**GPU Ray Tracing**:
- Hanika et al., "Two-Level Ray Tracing with Reordering", GI 2010
- Smits et al., "Direct Ray Tracing of Displacement Mapped Triangles", EGWR 2000

**Real-Time Displacement**:
- Policarpo et al., "Real-Time Relief Mapping", I3D 2005
- Tatarchuk, "Dynamic Parallax Occlusion Mapping", I3D 2006

### Implementation Resources

**Vulkan Ray Tracing**:
- NVIDIA Vulkan Ray Tracing Tutorial: https://nvpro-samples.github.io/vk_raytracing_tutorial_KHR/
- Khronos Vulkan Ray Tracing Guide: https://www.khronos.org/blog/vulkan-ray-tracing-final-specification-release

**Slang Shaders**:
- Slang User Guide: https://shader-slang.com/slang/user-guide/
- Slang stdlib reference (math, textures)

**glTF Extensions**:
- glTF 2.0 Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html
- Extension guidelines: https://github.com/KhronosGroup/glTF/tree/main/extensions

---

## Conclusion

### Key Takeaways for Implementation

1. **Displacement Mapping**: Adds real geometric detail via texture-driven vertex offset along normals
   - Historically required expensive tessellation
   - RMIP eliminates tessellation while maintaining accuracy

2. **RMIP Innovation**: Ping-pong between 2D texture space and 3D object space
   - Rectangular queries match anisotropic ray projections
   - Inverse mapping enables 3D→2D projection
   - Bounded traversal via direct 2D subdivision

3. **glTF Integration**: No standard displacement support
   - Implement custom `MATFORGE_displacement` extension
   - Fallback to external metadata if needed

4. **Implementation Priority**:
   - Week 1: RMIP builder + basic traversal
   - Week 2: Inverse mapping + custom intersection shader
   - Week 3: Integration + optimization

5. **Performance Expectations**:
   - 11× faster than TFDM (previous SOTA)
   - 3× less memory than tessellation
   - ~10-30 traversal steps per ray
   - Interactive frame rates (20-60 FPS) at 1080p with 4K displacement

### Ready for Implementation

With this analysis, we have:
- ✅ **Conceptual Understanding**: What displacement mapping is and why it matters
- ✅ **Historical Context**: How RMIP improves on prior work
- ✅ **Technical Foundation**: Algorithm details for implementation
- ✅ **Integration Plan**: How to fit into MatForge project
- ✅ **Performance Targets**: What to expect and optimize for

**Next Step**: Begin Week 1 implementation - RMIP data structure builder.

---

**Document Version**: 1.0
**Last Updated**: November 2025
**Author**: MatForge Development Team
**For**: CIS 5650 Final Project (University of Pennsylvania)
