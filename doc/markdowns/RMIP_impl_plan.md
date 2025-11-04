# RMIP Implementation Plan
## MatForge Project - CIS 5650 Fall 2025

**Implementation Team**: 2 Developers dedicated to RMIP
**Timeline**: November 1 - December 8, 2025 (5.5 weeks)
**Target Platform**: NVIDIA RTX 4070 (Vulkan 1.3 with ray tracing)
**Base Framework**: vk_gltf_renderer (nvpro-samples)

---

## Table of Contents

1. [Team Structure](#team-structure)
2. [Work Division Strategy](#work-division-strategy)
3. [Development Phases](#development-phases)
4. [Week-by-Week Schedule](#week-by-week-schedule)
5. [Detailed Task Breakdown](#detailed-task-breakdown)
6. [Integration Checkpoints](#integration-checkpoints)
7. [Testing Strategy](#testing-strategy)
8. [Risk Mitigation](#risk-mitigation)
9. [Deliverables Checklist](#deliverables-checklist)

---

## Team Structure

### Developer Roles

**Developer A: "Data Structures Lead"**
- **Primary Focus**: CPU-side infrastructure
- **Core Responsibilities**:
  - RMIP data structure builder
  - glTF extension handling
  - Resource management (Vulkan buffers, textures)
  - BLAS/TLAS modification for AABB geometry
  - Performance profiling tools

**Developer B: "Shader Lead"**
- **Primary Focus**: GPU-side implementation
  - RMIP traversal algorithm
  - Custom intersection shader
  - Inverse displacement mapping
  - Texel marching
  - Shader debugging and optimization

**Shared Responsibilities**:
- Code reviews (review each other's work daily)
- Integration testing (joint debugging sessions)
- Documentation (document as you go)
- Milestone presentations (split slides 50/50)

### Communication Protocol

**Daily Standups** (15 minutes, every morning):
- What did I complete yesterday?
- What will I work on today?
- Any blockers or dependencies?

**Integration Sessions** (2 hours, twice per week):
- Tuesday: Mid-week integration check
- Friday: End-of-week integration and testing

**Code Reviews**:
- All PRs require review from partner before merge
- Review within 24 hours
- Use GitHub PR comments for async discussion

---

## Work Division Strategy

### Parallel Development Approach

**Weeks 1-2**: Build foundations independently
- Developer A: RMIP builder and resource setup
- Developer B: Shader utilities and test harness
- **Sync Point**: End of Week 1 (basic data structures ready)

**Weeks 3-4**: Integration and iteration
- Joint debugging sessions
- A handles CPU-GPU data flow
- B handles shader-side traversal
- **Sync Point**: End of Week 3 (first full path trace)

**Week 5**: Optimization and polish
- A: Performance profiling and memory optimization
- B: Shader optimization and quality tuning
- **Sync Point**: Daily integration

### Dependency Graph

```
[Developer A]                           [Developer B]
    |                                        |
    v                                        v
RMIP Builder ──────────────────────→  RMIP Shader Interface
    |                                        |
    v                                        v
Resource Management ───────────────→  Inverse Mapping Utils
    |                                        |
    v                                        v
BLAS/AABB Setup ───────────────────→  Custom Intersection
    |                                        |
    v                                        v
    └────────→ INTEGRATION ←─────────────────┘
                    |
                    v
            Texel Marching & Optimization
                    |
                    v
            Testing & Benchmarking
```

---

## Development Phases

### Phase 1: Foundation (Week 1: Nov 1-8)
**Goal**: Build RMIP data structure and basic shader infrastructure

**Developer A Tasks**:
- [x] Environment setup and build verification
- [ ] RMIP data structure design (header file)
- [ ] Basic RMIP builder (min-max pyramid)
- [ ] Unit tests for RMIP builder

**Developer B Tasks**:
- [x] Environment setup and build verification
- [ ] Shader stub creation (intersection shader skeleton)
- [ ] Ray-triangle intersection utilities
- [ ] Shader test harness (standalone test)

**Milestone 1 Prep** (Due Nov 12):
- [ ] RMIP builder working for simple 256×256 test texture
- [ ] Custom intersection shader compiling and loading
- [ ] Basic ray-prism intersection test passing

---

### Phase 2: Core Algorithm (Week 2-3: Nov 9-22)
**Goal**: Implement full RMIP traversal algorithm

**Developer A Tasks**:
- [ ] glTF extension parser for displacement
- [ ] Vulkan buffer creation for RMIP data
- [ ] BLAS modification (triangles → AABBs)
- [ ] SBT setup for custom intersection shader

**Developer B Tasks**:
- [ ] Inverse displacement mapping implementation
- [ ] RMIP query function (rectangular region lookup)
- [ ] 3D bounding box computation
- [ ] Hierarchical traversal loop

**Integration Checkpoint** (End of Week 2):
- [ ] First successful RMIP intersection (even if slow)
- [ ] Displaced plane renders correctly
- [ ] Normal and UV correctly computed at hit point

---

### Phase 3: Texel Marching (Week 3: Nov 16-22)
**Goal**: Implement efficient texel marching for final intersection

**Developer A Tasks**:
- [ ] Texture coordinate tiling support
- [ ] Multi-material scene support
- [ ] Memory optimization (RMIP compression)

**Developer B Tasks**:
- [ ] Texel marching algorithm
- [ ] Implicit ray projection form
- [ ] Turning point computation
- [ ] Front-to-back traversal ordering

**Milestone 2 Prep** (Due Nov 24):
- [ ] Full RMIP pipeline working (builder → traversal → intersection)
- [ ] At least 2 test scenes with displacement
- [ ] Performance comparison vs. baseline (tessellation)

---

### Phase 4: Optimization (Week 4-5: Nov 23-Dec 6)
**Goal**: Performance tuning and quality improvements

**Developer A Tasks**:
- [ ] GPU profiling integration (Nsight)
- [ ] Memory bandwidth optimization
- [ ] RMIP resolution tuning
- [ ] Multi-bounce ray tracing integration

**Developer B Tasks**:
- [ ] Shader divergence reduction
- [ ] Cache-friendly traversal order
- [ ] Adaptive marching threshold
- [ ] Quality vs. performance modes

**Milestone 3 Prep** (Due Dec 1):
- [ ] 5+ materials with RMIP displacement
- [ ] Performance targets met (30+ FPS at 1080p)
- [ ] Comparison modes (RMIP on/off toggle)

---

### Phase 5: Polish & Documentation (Week 5-6: Nov 30-Dec 8)
**Goal**: Finalize for submission

**Developer A Tasks**:
- [ ] Code cleanup and documentation
- [ ] Build instructions and README
- [ ] Performance data collection
- [ ] Final presentation slides (implementation sections)

**Developer B Tasks**:
- [ ] Shader code documentation
- [ ] Known limitations documentation
- [ ] Visual quality comparison renders
- [ ] Final presentation slides (algorithm sections)

**Final Deliverable** (Due Dec 7):
- [ ] All code merged and tested
- [ ] Demo video recorded
- [ ] Presentation materials complete

---

## Week-by-Week Schedule

### Week 1: Nov 1-8 (Foundation)

#### Developer A Daily Schedule

**Friday Nov 1** (Today):
- [x] Clone repository, verify build
- [x] Read RMIP paper and analysis
- [ ] Create `src/rmip_builder.hpp` with data structure definitions
- [ ] Stub out `RMIPBuilder` class interface

**Saturday Nov 2**:
- [ ] Implement basic min-max mipmap builder (square regions only)
- [ ] Test with 256×256 test texture (checkerboard pattern)
- [ ] Verify min/max values are correct (unit test)

**Sunday Nov 3**:
- [ ] Extend to rectangular regions (power-of-two dimensions)
- [ ] Implement RMIP query function (CPU-side test)
- [ ] Test query correctness with known regions

**Monday Nov 4**:
- [ ] Create Vulkan buffer for RMIP data
- [ ] Upload RMIP data to GPU
- [ ] Bind RMIP buffer to shader descriptors

**Tuesday Nov 5** (Integration Session):
- [ ] Review Developer B's shader code
- [ ] Test CPU-GPU data transfer
- [ ] Debug any issues together

**Wednesday Nov 6**:
- [ ] Implement glTF displacement texture loading
- [ ] Hook RMIP builder into scene loading pipeline
- [ ] Test with DamagedHelmet model + custom displacement

**Thursday Nov 7**:
- [ ] Create AABB geometry for displaced primitives
- [ ] Compute loose bounds (base triangle + max displacement)
- [ ] Verify AABB bounds in validation layers

**Friday Nov 8** (End of Week 1):
- [ ] Code review with Developer B
- [ ] Integration testing
- [ ] Document Week 1 progress
- **Deliverable**: RMIP builder working, data on GPU

---

#### Developer B Daily Schedule

**Friday Nov 1** (Today):
- [x] Clone repository, verify build
- [x] Read RMIP paper and analysis
- [ ] Create `shaders/rmip_intersection.slang` skeleton
- [ ] Create `shaders/rmip_common.h.slang` for utilities

**Saturday Nov 2**:
- [ ] Implement basic ray-triangle intersection (object space)
- [ ] Implement barycentric coordinate computation
- [ ] Test with simple triangle (CPU reference test)

**Sunday Nov 3**:
- [ ] Implement triangle interpolation functions
  - `interpolate_position(Triangle, uv)`
  - `interpolate_normal(Triangle, uv)`
  - `interpolate_uv(Triangle, uv)`
- [ ] Unit test interpolation (compare with CPU)

**Monday Nov 4**:
- [ ] Study custom intersection shader API
  - `ObjectRayOrigin()`, `ObjectRayDirection()`
  - `ReportHit()`, `HitAttributes`
- [ ] Create minimal intersection shader (always reports hit at t=1.0)
- [ ] Test that shader compiles and loads

**Tuesday Nov 5** (Integration Session):
- [ ] Review Developer A's RMIP builder code
- [ ] Get RMIP data format specification
- [ ] Test shader descriptor bindings

**Wednesday Nov 6**:
- [ ] Implement ray-prism intersection
- [ ] Compute entry/exit points on base triangle
- [ ] Visualize intersection intervals (debug render)

**Thursday Nov 7**:
- [ ] Begin inverse displacement mapping
- [ ] Implement initial guess (project to base plane)
- [ ] Implement 1 iteration of Newton solver

**Friday Nov 8** (End of Week 1):
- [ ] Code review with Developer A
- [ ] Integration testing
- [ ] Document Week 1 progress
- **Deliverable**: Custom intersection shader working (basic)

---

### Week 2: Nov 9-15 (Core Traversal)

#### Developer A Daily Schedule

**Saturday Nov 9**:
- [ ] Implement SBT setup for custom intersection shader
- [ ] Create hit group with intersection shader
- [ ] Test ray tracing pipeline invokes shader

**Sunday Nov 10**:
- [ ] Modify BLAS creation for AABB geometry
- [ ] Handle mixed geometry (triangular + AABB)
- [ ] Verify acceleration structure builds correctly

**Monday Nov 11**:
- [ ] Implement glTF `MATFORGE_displacement` extension parser
- [ ] Load displacement texture and call RMIP builder
- [ ] Attach RMIP buffer to material

**Tuesday Nov 12** (Integration + Milestone 1):
- [ ] **MILESTONE 1 PRESENTATION**
- [ ] Integration testing with Developer B
- [ ] Debug RMIP query binding issues

**Wednesday Nov 13**:
- [ ] Implement tiling support (repeat displacement map)
- [ ] Handle texture coordinate wrapping
- [ ] Test tiled displacement (brick pattern)

**Thursday Nov 14**:
- [ ] Create debug visualization (AABB bounds)
- [ ] Add UI toggle for RMIP on/off
- [ ] Test toggling between RMIP and baseline

**Friday Nov 15** (End of Week 2):
- [ ] Code review
- [ ] Performance profiling setup
- **Deliverable**: Full GPU pipeline ready for traversal

---

#### Developer B Daily Schedule

**Saturday Nov 9**:
- [ ] Complete inverse displacement (full Newton iteration)
- [ ] Test convergence on curved triangles
- [ ] Handle edge cases (ray misses triangle)

**Sunday Nov 10**:
- [ ] Implement RMIP query function in shader
- [ ] Sample RMIP buffer for rectangular region
- [ ] Return min/max displacement

**Monday Nov 11**:
- [ ] Implement 3D bounding box computation
  - Sample base triangle at UV rectangle corners
  - Expand/contract by displacement bounds
- [ ] Test AABB correctness (visualize in CPU)

**Tuesday Nov 12** (Integration + Milestone 1):
- [ ] **MILESTONE 1 PRESENTATION**
- [ ] Integration with Developer A's pipeline
- [ ] First end-to-end test (may be slow)

**Wednesday Nov 13**:
- [ ] Implement 2D bound subdivision
- [ ] Find longest axis, compute split point
- [ ] Test split balancing (should be ~50/50)

**Thursday Nov 14**:
- [ ] Implement hierarchical traversal loop
- [ ] Stack management (LIFO, front-to-back)
- [ ] Early termination on first hit

**Friday Nov 15** (End of Week 2):
- [ ] Code review
- [ ] Performance profiling (iteration count)
- **Deliverable**: RMIP traversal working (may be slow)

---

### Week 3: Nov 16-22 (Texel Marching & Optimization)

#### Developer A Daily Schedule

**Saturday Nov 16**:
- [ ] Implement RMIP compression (lower resolution)
- [ ] Test memory savings vs. quality trade-off
- [ ] Document compression parameters

**Sunday Nov 17**:
- [ ] Add multiple displacement materials to test scene
- [ ] Create material library loader
- [ ] Test scene with 3+ displaced objects

**Monday Nov 18**:
- [ ] Integrate with path tracer BSDF sampling
- [ ] Ensure hit state is computed correctly
- [ ] Test with global illumination (multi-bounce)

**Tuesday Nov 19** (Integration Session):
- [ ] Debug texel marching issues with Developer B
- [ ] Performance analysis (where is time spent?)
- [ ] Plan optimization strategy

**Wednesday Nov 20**:
- [ ] Implement adaptive RMIP resolution
- [ ] Higher resolution for close-up, lower for distance
- [ ] Test LOD switching

**Thursday Nov 21**:
- [ ] Collect performance data for milestone
- [ ] Create comparison scenes (RMIP vs. baseline)
- [ ] Prepare Milestone 2 slides

**Friday Nov 22** (End of Week 3):
- [ ] Code review and integration
- **Deliverable**: 3+ materials, performance data

---

#### Developer B Daily Schedule

**Saturday Nov 16**:
- [ ] Implement implicit ray projection form
  - `ψ(u,v) = det(P(u,v) - O, N(u,v), D)`
- [ ] Test zero-crossing detection

**Sunday Nov 17**:
- [ ] Implement turning point computation
  - Solve `∂ψ/∂u = 0` and `∂ψ/∂v = 0`
- [ ] Split initial ray projection at turning points

**Monday Nov 18**:
- [ ] Implement texel marching algorithm
- [ ] Determine ray exit edge per texel
- [ ] March through texels until hit or exit

**Tuesday Nov 19** (Integration Session):
- [ ] Debug texel marching with Developer A
- [ ] Test different marching thresholds
- [ ] Analyze shader performance (Nsight)

**Wednesday Nov 20**:
- [ ] Optimize traversal (reduce divergence)
- [ ] Test different stack sizes
- [ ] Implement adaptive traversal depth

**Thursday Nov 21**:
- [ ] Quality tuning (marching step size)
- [ ] Test edge cases (grazing angles, backfaces)
- [ ] Prepare Milestone 2 demo scenes

**Friday Nov 22** (End of Week 3):
- [ ] Code review and integration
- **Deliverable**: Texel marching working, quality improved

---

### Week 4: Nov 23-29 (Performance & Polish)

**Saturday Nov 23**:
- [ ] Joint debugging session (both developers)
- [ ] Fix any critical bugs

**Sunday Nov 24**:
- [ ] **MILESTONE 2 PRESENTATION**
- [ ] Plan Week 4 optimization priorities

**Monday Nov 25**:
- **Developer A**: Memory bandwidth profiling
- **Developer B**: Shader occupancy analysis

**Tuesday Nov 26** (Integration Session):
- [ ] Implement agreed optimizations
- [ ] A/B test performance improvements

**Wednesday Nov 27** (Thanksgiving):
- [ ] (Light work) Documentation and cleanup

**Thursday Nov 28** (Thanksgiving):
- [ ] (Off day)

**Friday Nov 29**:
- [ ] Integration and testing
- [ ] Prepare for Milestone 3

---

### Week 5: Nov 30-Dec 6 (Final Polish)

**Sunday Dec 1**:
- [ ] **MILESTONE 3 PRESENTATION**
- [ ] Final bug list prioritization

**Monday Dec 2**:
- **Developer A**: Build instructions and setup documentation
- **Developer B**: Algorithm documentation and comments

**Tuesday Dec 3** (Integration Session):
- [ ] Final code review (all code)
- [ ] Merge all feature branches

**Wednesday Dec 4**:
- [ ] Demo video planning and recording
- [ ] Screenshot collection

**Thursday Dec 5**:
- [ ] Final presentation slide creation
- [ ] Practice presentation

**Friday Dec 6**:
- [ ] Final testing and validation
- [ ] Package submission materials

---

### Week 6: Dec 7-8 (Submission)

**Saturday Dec 7**:
- [ ] **FINAL PROJECT DUE (end of day)**
- [ ] Submit all materials

**Sunday Dec 8**:
- [ ] **FINAL PRESENTATION DUE (4pm)**
- [ ] **LIVE PRESENTATION (5:30pm)**

---

## Detailed Task Breakdown

### Task 1: RMIP Data Structure Builder (Developer A)

**File**: `src/rmip_builder.hpp`, `src/rmip_builder.cpp`

**Interface Design**:
```cpp
class RMIPBuilder {
public:
    struct Config {
        uint32_t resolution = 1024;     // Output RMIP resolution
        bool     compression = true;     // Enable compression
        uint32_t compressionLevel = 2;  // 0=none, 1=low, 2=medium, 3=high
    };

    struct RMIPData {
        std::vector<float> data;        // Interleaved min/max values
        uint32_t           width;       // Resolution
        uint32_t           height;
        uint32_t           levels;      // Number of hierarchy levels
        uint32_t           channels;    // 2 (min, max)
    };

    // Build RMIP from displacement texture
    RMIPData build(const float* heightMap, uint32_t width, uint32_t height, const Config& config);

    // Query RMIP (CPU-side testing)
    std::pair<float, float> query(const RMIPData& rmip, const Rect2D& region);
};
```

**Implementation Steps**:
1. Load height map data
2. Build base level (full resolution min/max)
3. Build hierarchy levels (power-of-two rectangles)
4. Apply compression (if enabled)
5. Pack data for GPU upload

**Testing**:
- Unit test: Query known regions, verify min/max correct
- Visual test: Render min/max as heatmap
- Performance test: Build time for 4K texture (<2 seconds)

**Acceptance Criteria**:
- [ ] Builds RMIP for arbitrary resolution texture
- [ ] Query returns correct min/max for rectangular regions
- [ ] Compression reduces size by 30-70% with <5% error
- [ ] GPU buffer upload succeeds

**Estimated Time**: 12-16 hours (2-3 days)

---

### Task 2: Inverse Displacement Mapping (Developer B)

**File**: `shaders/rmip_common.h.slang`

**Function Signature**:
```slang
// Inverse displacement: 3D world position → 2D texture coordinates
// Returns: UV coordinates where S(u,v) = worldPos (closest point)
float2 inverseDisplacement(
    float3 worldPos,        // Query point (on ray)
    Triangle tri,           // Base triangle
    Texture2D<float> dispMap,  // Displacement texture
    float dispScale         // Displacement scale factor
)
```

**Algorithm** (from paper Section 4.1):
```slang
float2 inverseDisplacement(float3 worldPos, Triangle tri, Texture2D<float> dispMap, float dispScale) {
    // 1. Initial guess: Project to base triangle plane
    float3 bary = barycentric(worldPos, tri.v0, tri.v1, tri.v2);
    float2 uv = tri.uv0 * bary.x + tri.uv1 * bary.y + tri.uv2 * bary.z;

    // Clamp to valid range
    uv = saturate(uv);

    // 2. Newton iteration
    const int MAX_ITER = 5;
    for (int i = 0; i < MAX_ITER; i++) {
        // Sample displaced position at current UV
        float3 P_base = interpolate_position(tri, uv);
        float3 N = interpolate_normal(tri, uv);
        float h = dispMap.SampleLevel(sampler, uv, 0).r;
        float3 P_displaced = P_base + h * dispScale * normalize(N);

        // Residual: r = P_displaced - worldPos
        float3 r = P_displaced - worldPos;

        // Check convergence
        if (length(r) < 1e-5) {
            break;
        }

        // Jacobian: J = [∂P/∂u, ∂P/∂v]
        // Compute via finite differences
        const float eps = 1e-4;
        float3 P_u = (sample_displaced(tri, uv + float2(eps, 0), dispMap, dispScale) - P_displaced) / eps;
        float3 P_v = (sample_displaced(tri, uv + float2(0, eps), dispMap, dispScale) - P_displaced) / eps;

        // Solve J * delta_uv = r (least squares)
        // delta_uv = (J^T J)^-1 J^T r
        float2x2 JtJ = float2x2(
            dot(P_u, P_u), dot(P_u, P_v),
            dot(P_v, P_u), dot(P_v, P_v)
        );
        float2 Jtr = float2(dot(P_u, r), dot(P_v, r));

        float det = JtJ[0][0] * JtJ[1][1] - JtJ[0][1] * JtJ[1][0];
        if (abs(det) < 1e-8) {
            break;  // Singular, stop
        }

        float2x2 JtJ_inv = float2x2(
            JtJ[1][1], -JtJ[0][1],
            -JtJ[1][0], JtJ[0][0]
        ) / det;

        float2 delta_uv = mul(JtJ_inv, Jtr);

        // Update UV
        uv -= delta_uv;
        uv = saturate(uv);  // Keep in valid range
    }

    return uv;
}
```

**Testing**:
- Known point test: Displace a point, inverse map it back (should match original UV)
- Edge case test: Points outside triangle (should clamp to nearest)
- Performance test: Iteration count (should be 3-5 on average)

**Acceptance Criteria**:
- [ ] Converges in 3-5 iterations for flat/moderate curvature
- [ ] Converges in <10 iterations for high curvature
- [ ] Handles edge cases (no crashes, reasonable fallback)
- [ ] Performance: <50 ALU ops total

**Estimated Time**: 16-20 hours (3-4 days)

---

### Task 3: RMIP Traversal (Developer B)

**File**: `shaders/rmip_intersection.slang`

**Main Entry Point**:
```slang
[shader("intersection")]
void rmipIntersection() {
    // Get ray information
    RayDesc ray;
    ray.Origin = ObjectRayOrigin();
    ray.Direction = ObjectRayDirection();
    ray.TMin = RayTMin();
    ray.TMax = RayTMax();

    // Get geometry information
    uint primID = PrimitiveIndex();
    Triangle tri = loadTriangle(primID);

    // Get RMIP data
    uint matID = getMaterialID(primID);
    RMIPTexture rmip = getRMIPTexture(matID);
    Texture2D<float> dispMap = getDisplacementMap(matID);
    float dispScale = getDisplacementScale(matID);

    // Traverse RMIP
    HitInfo hit = traverseRMIP(ray, tri, rmip, dispMap, dispScale);

    if (hit.valid) {
        // Report hit
        HitAttributes attr;
        attr.uv = hit.uv;
        attr.t = hit.t;
        ReportHit(hit.t, 0, attr);
    }
}
```

**Core Traversal Function**:
```slang
struct HitInfo {
    bool valid;
    float t;
    float2 uv;
};

HitInfo traverseRMIP(
    RayDesc ray,
    Triangle tri,
    RMIPTexture rmip,
    Texture2D<float> dispMap,
    float dispScale
) {
    // 1. Ray-prism intersection (loose AABB)
    float2 t_prism = intersectPrism(ray, tri, dispScale);
    if (t_prism.x > t_prism.y || t_prism.y < ray.TMin || t_prism.x > ray.TMax) {
        return HitInfo::invalid();
    }

    // 2. Inverse mapping to get initial 2D bounds
    float3 entry = ray.Origin + t_prism.x * ray.Direction;
    float3 exit = ray.Origin + t_prism.y * ray.Direction;
    float2 uv_entry = inverseDisplacement(entry, tri, dispMap, dispScale);
    float2 uv_exit = inverseDisplacement(exit, tri, dispMap, dispScale);

    // 3. Compute initial rectangular bound
    Rect2D bound = Rect2D(min(uv_entry, uv_exit), max(uv_entry, uv_exit));

    // 4. Find turning points and split
    // (Simplified: skip turning points for first implementation)

    // 5. Hierarchical traversal (stack-based)
    const int MAX_STACK = 32;
    Rect2D stack[MAX_STACK];
    int stackPtr = 0;
    stack[stackPtr++] = bound;

    HitInfo closestHit = HitInfo::invalid();

    while (stackPtr > 0) {
        Rect2D current = stack[--stackPtr];  // Pop (front-to-back)

        // Check if small enough for texel marching
        float area = (current.max.x - current.min.x) * (current.max.y - current.min.y);
        if (area < TEXEL_MARCH_THRESHOLD) {
            HitInfo hit = texelMarch(ray, tri, current, dispMap, dispScale);
            if (hit.valid && (!closestHit.valid || hit.t < closestHit.t)) {
                closestHit = hit;
                // Early exit (front-to-back traversal)
                break;
            }
            continue;
        }

        // Query RMIP for displacement bounds
        float2 dispBounds = rmip.query(current);
        float dispMin = dispBounds.x;
        float dispMax = dispBounds.y;

        // Compute 3D bounding box
        AABB box = computeDisplacedBounds(tri, current, dispMin * dispScale, dispMax * dispScale);

        // Ray-box intersection
        float2 t_box = intersectAABB(ray, box);
        if (t_box.x > t_box.y || t_box.y < ray.TMin) {
            continue;  // Miss, skip this region
        }

        // Subdivide (split along longer axis)
        Rect2D front, back;
        subdivide2D(current, front, back);

        // Push to stack (back first, so front is processed first)
        if (stackPtr < MAX_STACK) {
            stack[stackPtr++] = back;
            stack[stackPtr++] = front;
        }
    }

    return closestHit;
}
```

**Acceptance Criteria**:
- [ ] Successfully intersects displaced surfaces
- [ ] Front-to-back traversal (first hit is closest)
- [ ] Stack doesn't overflow (monitor max stack depth)
- [ ] Performance: 10-30 steps average per ray

**Estimated Time**: 24-32 hours (4-5 days)

---

### Task 4: Texel Marching (Developer B)

**File**: `shaders/rmip_intersection.slang`

**Implementation**:
```slang
HitInfo texelMarch(
    RayDesc ray,
    Triangle tri,
    Rect2D uvBound,
    Texture2D<float> dispMap,
    float dispScale
) {
    // Get texel coordinates for bound
    uint2 texSize = getTextureSize(dispMap);
    uint2 texelMin = uint2(uvBound.min * texSize);
    uint2 texelMax = uint2(uvBound.max * texSize);

    // March through texels
    // Start from texel closest to ray origin
    uint2 texel = texelMin;

    const int MAX_TEXELS = 64;
    int numTexels = 0;

    while (numTexels < MAX_TEXELS) {
        numTexels++;

        // Sample displacement at texel center
        float2 uv = (float2(texel) + 0.5) / texSize;
        float3 P_base = interpolate_position(tri, uv);
        float3 N = interpolate_normal(tri, uv);
        float h = dispMap.SampleLevel(sampler, uv, 0).r;
        float3 P_displaced = P_base + h * dispScale * normalize(N);

        // Intersect ray with displaced surface (plane approximation)
        float3 V_displaced = P_displaced - ray.Origin;
        float t = dot(V_displaced, N) / dot(ray.Direction, N);

        // Check if valid hit
        if (t >= ray.TMin && t <= ray.TMax) {
            float3 hitPos = ray.Origin + t * ray.Direction;
            float dist = length(hitPos - P_displaced);

            if (dist < 0.01 * dispScale) {  // Tolerance
                HitInfo hit;
                hit.valid = true;
                hit.t = t;
                hit.uv = uv;
                return hit;
            }
        }

        // Determine next texel (exit edge)
        // Use implicit form to find which edge ray crosses
        int exitEdge = findExitEdge(ray, tri, texel, texSize);
        if (exitEdge < 0) {
            break;  // No exit edge found
        }

        texel = getNeighborTexel(texel, exitEdge);

        // Check if out of bounds
        if (any(texel < texelMin) || any(texel > texelMax)) {
            break;
        }
    }

    return HitInfo::invalid();
}
```

**Acceptance Criteria**:
- [ ] Correctly marches through texels
- [ ] Finds intersection within tolerance
- [ ] No infinite loops (max iteration count)
- [ ] Performance: <20 texels per ray on average

**Estimated Time**: 12-16 hours (2-3 days)

---

### Task 5: BLAS/SBT Setup (Developer A)

**File**: `src/renderer_pathtracer.cpp`

**BLAS Modification**:
```cpp
void PathTracer::createAccelerationStructure() {
    for (const auto& primitive : scene.primitives) {
        VkAccelerationStructureGeometryKHR geometry = {};

        if (primitive.material->hasRMIPDisplacement) {
            // Use AABB geometry for RMIP-displaced primitives
            geometry.geometryType = VK_GEOMETRY_TYPE_AABBS_KHR;
            geometry.flags = VK_GEOMETRY_OPAQUE_BIT_KHR;

            // Compute loose AABB bounds
            std::vector<VkAabbPositionsKHR> aabbs;
            for (const auto& triangle : primitive.triangles) {
                VkAabbPositionsKHR aabb = computeLooseAABB(
                    triangle,
                    primitive.material->displacementScale
                );
                aabbs.push_back(aabb);
            }

            // Create AABB buffer
            geometry.geometry.aabbs.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_AABBS_DATA_KHR;
            geometry.geometry.aabbs.data = createBuffer(aabbs);
            geometry.geometry.aabbs.stride = sizeof(VkAabbPositionsKHR);
        } else {
            // Standard triangle geometry
            geometry.geometryType = VK_GEOMETRY_TYPE_TRIANGLES_KHR;
            // ... existing code ...
        }

        // Build BLAS
        // ... existing code ...
    }
}
```

**SBT Setup**:
```cpp
void PathTracer::createShaderBindingTable() {
    // Ray generation shader (existing)
    // ...

    // Miss shader (existing)
    // ...

    // Hit groups
    std::vector<VkRayTracingShaderGroupCreateInfoKHR> hitGroups;

    // Standard hit group (triangular geometry)
    VkRayTracingShaderGroupCreateInfoKHR triangleHitGroup = {};
    triangleHitGroup.type = VK_RAY_TRACING_SHADER_GROUP_TYPE_TRIANGLES_HIT_GROUP_KHR;
    triangleHitGroup.closestHitShader = closestHitIndex;
    triangleHitGroup.anyHitShader = VK_SHADER_UNUSED_KHR;
    hitGroups.push_back(triangleHitGroup);

    // RMIP hit group (AABB geometry with custom intersection)
    VkRayTracingShaderGroupCreateInfoKHR rmipHitGroup = {};
    rmipHitGroup.type = VK_RAY_TRACING_SHADER_GROUP_TYPE_PROCEDURAL_HIT_GROUP_KHR;
    rmipHitGroup.closestHitShader = closestHitIndex;  // Same closest hit shader
    rmipHitGroup.intersectionShader = rmipIntersectionIndex;  // Custom intersection
    rmipHitGroup.anyHitShader = VK_SHADER_UNUSED_KHR;
    hitGroups.push_back(rmipHitGroup);

    // Build SBT
    // ... existing code ...
}
```

**Acceptance Criteria**:
- [ ] AABB geometry builds successfully
- [ ] Custom intersection shader is invoked
- [ ] No validation errors
- [ ] Can toggle between RMIP and standard geometry

**Estimated Time**: 16-20 hours (3-4 days)

---

## Integration Checkpoints

### Checkpoint 1: Data Flow Validation (End of Week 1)

**Test**: Verify CPU → GPU data transfer

**Steps**:
1. Developer A: Build RMIP for 256×256 checkerboard
2. Developer A: Upload to GPU buffer
3. Developer B: Create test shader that samples RMIP
4. Developer B: Visualize RMIP min/max as color (red=min, green=max)
5. Both: Verify output image looks correct

**Success Criteria**:
- [ ] RMIP data uploads correctly (no corruption)
- [ ] Shader can read RMIP buffer
- [ ] Visualization matches expected pattern

---

### Checkpoint 2: First Intersection (Mid Week 2)

**Test**: Intersect a single displaced plane

**Setup**:
- Simple scene: One quad with sine wave displacement
- Camera: Looking straight at quad
- Expected: See wavy surface

**Steps**:
1. Developer A: Create AABB for quad
2. Developer B: Implement basic traversal (no optimizations)
3. Both: Run path tracer, check for hits
4. Both: Debug if no intersection or incorrect results

**Success Criteria**:
- [ ] Ray-AABB intersection works
- [ ] Custom intersection shader is invoked
- [ ] Displaced surface is visible (even if slow)

---

### Checkpoint 3: Correct Normal and UV (End of Week 2)

**Test**: Verify hit attributes are correct

**Setup**:
- Displaced sphere with texture
- Visualize: UV as color (R=U, G=V), normal as color

**Steps**:
1. Developer B: Compute UV at hit point from inverse mapping
2. Developer B: Compute normal (derivative of displaced surface)
3. Both: Render and check UV/normal visualization
4. Both: Compare with reference (tessellated mesh)

**Success Criteria**:
- [ ] UVs match reference (texture aligned correctly)
- [ ] Normals match reference (shading looks correct)
- [ ] No seams or discontinuities

---

### Checkpoint 4: Performance Baseline (Mid Week 3)

**Test**: Measure performance vs. targets

**Metrics**:
- Frame time (ms per frame)
- Ray throughput (Mrays/sec)
- RMIP traversal steps (avg per ray)
- Memory usage (MB)

**Target**:
- 1080p: 30+ FPS (< 33ms)
- Traversal: 10-30 steps average
- Memory: < 100MB for 4K displacement

**Steps**:
1. Developer A: Integrate Nsight profiler
2. Developer B: Add performance counters to shader
3. Both: Run benchmark scenes
4. Both: Identify bottlenecks

**Success Criteria**:
- [ ] Profiler working correctly
- [ ] Can measure per-component time
- [ ] Have baseline data for optimization

---

## Testing Strategy

### Unit Tests (Continuous)

**CPU-Side (Developer A)**:
```cpp
// Test RMIP builder
TEST(RMIPBuilder, MinMaxCorrect) {
    float heightMap[256*256] = { /* known pattern */ };
    auto rmip = builder.build(heightMap, 256, 256);

    // Query region
    auto [min, max] = builder.query(rmip, Rect2D{{0,0}, {0.5,0.5}});

    EXPECT_FLOAT_EQ(min, expectedMin);
    EXPECT_FLOAT_EQ(max, expectedMax);
}
```

**GPU-Side (Developer B)**:
```slang
// Test inverse displacement
[numthreads(1,1,1)]
void testInverseDisplacement() {
    Triangle tri = /* test triangle */;
    float2 originalUV = float2(0.5, 0.3);

    // Forward: UV → 3D
    float3 worldPos = displacePoint(tri, originalUV);

    // Inverse: 3D → UV
    float2 reconstructedUV = inverseDisplacement(worldPos, tri, ...);

    // Should match
    float error = length(originalUV - reconstructedUV);
    assert(error < 1e-3);
}
```

### Integration Tests (Weekly)

**Week 1**:
- [ ] Test: RMIP data on GPU
- [ ] Test: Custom intersection shader compiles

**Week 2**:
- [ ] Test: Single plane intersection
- [ ] Test: Correct UVs and normals

**Week 3**:
- [ ] Test: Multiple objects with displacement
- [ ] Test: Tiled displacement

**Week 4**:
- [ ] Test: Full path tracer integration
- [ ] Test: Performance benchmarks

### Visual Tests (Milestone Checkpoints)

**Reference Images**:
- Create ground truth with tessellation or offline renderer
- Compare RMIP output pixel-by-pixel (PSNR, SSIM)

**Test Scenes**:
1. **Sine Wave Plane**: Analytical displacement, easy to verify
2. **Brick Wall**: Tiled displacement, test edge cases
3. **Rough Stone**: Complex high-frequency displacement
4. **Sphere**: Curved base geometry, test inverse mapping

**Acceptance**:
- Visual difference imperceptible (<1% RMSE)
- No artifacts (holes, z-fighting, seams)

---

## Risk Mitigation

### Risk 1: RMIP Traversal Too Slow

**Probability**: Medium
**Impact**: High (fails performance targets)

**Mitigation**:
- **Week 1**: Implement basic version first, profile early
- **Week 3**: If slow, reduce RMIP resolution (4K → 1K)
- **Week 4**: If still slow, implement fallback (parallax occlusion mapping)

**Contingency**:
- Show that RMIP is faster than TFDM (even if not real-time)
- Document as "future work: optimization for 60 FPS"

---

### Risk 2: Inverse Displacement Doesn't Converge

**Probability**: Medium
**Impact**: Medium (incorrect intersections)

**Mitigation**:
- **Week 2**: Test on simple geometry first (flat triangles)
- **Week 2**: Implement robust initial guess (projection to base plane)
- **Week 3**: Add fallback (skip iteration if not converging)

**Contingency**:
- Limit to nearly-flat base geometry
- Document limitation: "Requires base mesh tessellation for high curvature"

---

### Risk 3: Complex glTF Extension Integration

**Probability**: Low
**Impact**: Low (can use simple scene format)

**Mitigation**:
- **Week 2**: Start with hardcoded displacement (no glTF)
- **Week 3**: Implement custom JSON loader (bypass glTF)
- **Week 4**: Polish glTF extension (if time permits)

**Contingency**:
- External material files (not embedded in glTF)
- Document: "Future work: standard glTF extension proposal"

---

### Risk 4: Team Member Blocked

**Probability**: Medium
**Impact**: Medium (delays schedule)

**Mitigation**:
- **Daily**: Communicate blockers immediately
- **Weekly**: Review dependencies, adjust if needed
- **Continuous**: Document interface contracts clearly

**Contingency**:
- Pair programming session (work together to unblock)
- Reassign tasks if one path is critical-path blocked

---

## Deliverables Checklist

### Milestone 1 (Nov 12)

**Developer A**:
- [x] Repository cloned and build verified
- [ ] RMIP builder implemented and tested
- [ ] RMIP data uploaded to GPU
- [ ] Basic AABB geometry created

**Developer B**:
- [x] Repository cloned and build verified
- [ ] Custom intersection shader compiling
- [ ] Ray-triangle utilities implemented
- [ ] Basic inverse mapping working

**Joint**:
- [ ] Integration test: Data flows CPU → GPU → Shader
- [ ] Presentation slides (5 minutes)
- [ ] Demo: Visualize RMIP data (even if not intersecting yet)

---

### Milestone 2 (Nov 24)

**Developer A**:
- [ ] glTF displacement loading
- [ ] SBT setup complete
- [ ] Multiple materials supported
- [ ] Performance profiling integrated

**Developer B**:
- [ ] Full RMIP traversal working
- [ ] Texel marching implemented
- [ ] Quality tuning complete
- [ ] Shader performance optimized

**Joint**:
- [ ] Integration test: Full path tracing with 2+ displaced objects
- [ ] Performance comparison: RMIP vs. baseline (FPS, memory)
- [ ] Presentation slides (10 minutes)
- [ ] Demo: Interactive scene with displacement

---

### Milestone 3 (Dec 1)

**Developer A**:
- [ ] 5+ materials in library
- [ ] LOD system (if time)
- [ ] Memory optimization complete
- [ ] Build documentation

**Developer B**:
- [ ] All shader code documented
- [ ] Known limitations documented
- [ ] Quality vs. performance modes
- [ ] Algorithm documentation

**Joint**:
- [ ] Integration test: Full material library
- [ ] Benchmarks: FPS at different resolutions
- [ ] Presentation slides (10 minutes)
- [ ] Demo: Material showcase scene

---

### Final Submission (Dec 7)

**Code**:
- [ ] All code merged to `master` branch
- [ ] No compiler warnings
- [ ] Passes validation layers (Vulkan)
- [ ] Build instructions in README

**Documentation**:
- [ ] RMIP implementation documented
- [ ] API documentation (Doxygen)
- [ ] Performance analysis writeup
- [ ] Known limitations listed

**Media**:
- [ ] Demo video (3-5 minutes)
- [ ] Screenshots (10+ images)
- [ ] Performance graphs (FPS, memory, etc.)

**Presentation**:
- [ ] Final slides (15 minutes)
- [ ] Live demo prepared
- [ ] Backup video (in case live demo fails)

---

## Communication Templates

### Daily Standup (Async in Discord/Slack)

**Format**:
```
**Developer A** - [Date]
✅ Yesterday: Implemented RMIP builder base class
🎯 Today: Add compression support
🚧 Blockers: None

**Developer B** - [Date]
✅ Yesterday: Inverse mapping initial guess working
🎯 Today: Newton iteration implementation
🚧 Blockers: Need RMIP data format spec from Dev A
```

---

### Integration Session Notes

**Format**:
```
**Integration Session** - [Date]
📌 Goal: Test CPU-GPU data transfer
✅ Completed:
  - RMIP buffer uploads correctly
  - Shader can read data
❌ Issues:
  - Stride mismatch in buffer (fixed)
  - Sampler binding wrong (fixed)
📋 Next Steps:
  - Dev A: Add tiling support
  - Dev B: Implement traversal loop
🗓️ Next Session: [Date + 3 days]
```

---

### Bug Report

**Format**:
```
**Bug**: Inverse mapping doesn't converge for curved triangles

**Reported By**: Developer B
**Date**: Nov 10
**Priority**: High
**Assigned To**: Developer B

**Symptoms**:
- Iteration count exceeds 10 for triangles with high curvature
- UV coordinates end up outside [0,1] range

**Root Cause**:
- Initial guess projects to base plane, which is far from actual surface
- Jacobian becomes ill-conditioned

**Fix**:
- Use better initial guess (sample displacement at projected point)
- Add damping factor to Newton step
- Clamp UV to valid range each iteration

**Status**: Fixed
**Verified By**: Developer A
```

---

## Success Metrics

### Technical Metrics

**Performance**:
- [ ] 30+ FPS at 1080p with 4K displacement (Balanced preset)
- [ ] 60+ FPS at 1080p with 2K displacement (Interactive preset)
- [ ] 10-30 traversal steps per ray (average)

**Quality**:
- [ ] PSNR > 40 dB vs. ground truth (tessellation)
- [ ] No visible artifacts (holes, seams, z-fighting)
- [ ] Correct silhouettes (displaced edges visible)

**Memory**:
- [ ] < 50 MB per 4K displacement (with compression)
- [ ] 3× less than tessellation baseline
- [ ] < 2 GB total for 5-material scene

### Project Metrics

**Code Quality**:
- [ ] No compiler warnings
- [ ] Passes Vulkan validation layers
- [ ] Code review approval from partner
- [ ] Documentation coverage > 80%

**Schedule**:
- [ ] Milestone 1: On time (Nov 12)
- [ ] Milestone 2: On time (Nov 24)
- [ ] Milestone 3: On time (Dec 1)
- [ ] Final: On time (Dec 7)

**Collaboration**:
- [ ] Daily standups completed (95%+ attendance)
- [ ] Integration sessions completed (100%)
- [ ] No merge conflicts or broken builds
- [ ] Equal contribution (measured by commits, reviews)

---

## Conclusion

This implementation plan provides a **structured roadmap** for implementing RMIP with 2 developers over 5.5 weeks. Key features:

✅ **Clear Role Division**: Developer A (CPU), Developer B (GPU)
✅ **Parallel Development**: Independent work Weeks 1-2, joint Weeks 3-5
✅ **Integration Checkpoints**: 4 major checkpoints to verify progress
✅ **Risk Mitigation**: Fallback plans for each major risk
✅ **Detailed Tasks**: 5 core tasks with code snippets and acceptance criteria
✅ **Daily Schedule**: Hour-by-hour breakdown for Week 1-2

**Next Steps**:
1. Both developers review this plan
2. Customize daily schedule to personal working style
3. Set up communication channels (Discord, GitHub, etc.)
4. Begin Week 1 tasks (RMIP builder + shader skeleton)

**Remember**: This is a living document. Update as you learn and adapt!

---

**Document Version**: 1.0
**Created**: November 1, 2025
**Authors**: MatForge RMIP Team
**Last Updated**: November 1, 2025
