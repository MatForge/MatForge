# RMIP Implementation Plan
## MatForge Project - CIS 5650 Fall 2025

**Implementation Team**: Person A (Single Developer - RMIP Specialist)
**Timeline**: November 3 - December 7, 2025 (5 weeks)
**Target Platform**: NVIDIA RTX 4070 (Vulkan 1.3 with ray tracing)
**Base Framework**: vk_gltf_renderer (nvpro-samples)
**Team Context**: Part of 3-person team (Person A: RMIP, Person B: Quad LDS, Person C: Bounded VNDF + Fast-MSX)

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

### Developer Role: Person A - RMIP Specialist

**Full-Stack Responsibility**: Both CPU and GPU implementation
- **CPU-Side Infrastructure**:
  - RMIP data structure builder
  - glTF extension handling
  - Resource management (Vulkan buffers, textures)
  - BLAS/TLAS modification for AABB geometry
  - Performance profiling tools

- **GPU-Side Implementation**:
  - RMIP traversal algorithm
  - Custom intersection shader
  - Inverse displacement mapping
  - Texel marching
  - Shader debugging and optimization

**Team Integration Points**:
- Coordinate with Person B (Quad LDS) for random number generation integration
- Coordinate with Person C (Bounded VNDF + Fast-MSX) for material system integration
- Participate in team milestones and presentations

### Communication Protocol

**Team Standups** (15 minutes, 3× per week - Mon/Wed/Fri):
- Update on RMIP progress
- Report blockers or dependencies on other team members
- Coordinate integration points

**Team Integration Sessions** (2 hours, Tuesday evenings):
- Demo RMIP progress to team
- Test integration with Quad LDS sampling
- Coordinate material library creation

**Code Reviews**:
- Request reviews from Person B or C for major components
- Provide reviews for teammates' code
- Use GitHub PR comments for documentation

---

## Work Division Strategy

### Sequential Full-Stack Development Approach

**Week 1 (Nov 3-9)**: CPU Infrastructure Foundation
- RMIP data structure builder (C++)
- Resource management and Vulkan buffers
- Initial testing and validation
- **Checkpoint**: RMIP builder working, data on GPU

**Week 2 (Nov 10-16)**: GPU Shader Foundation
- Custom intersection shader skeleton
- Inverse displacement mapping
- Ray-triangle utilities
- **Checkpoint**: Basic shader compiling, inverse mapping working

**Week 3 (Nov 17-23)**: Core Algorithm Integration
- RMIP traversal algorithm
- BLAS/AABB setup
- SBT configuration
- First end-to-end intersection test
- **Milestone 2** (Nov 24): Full pipeline working

**Week 4 (Nov 24-30)**: Texel Marching & Optimization
- Texel marching implementation
- Performance profiling and optimization
- Multi-material support
- **Milestone 3** (Dec 1): 3+ materials, performance targets met

**Week 5 (Dec 1-7)**: Polish & Documentation
- Code cleanup and documentation
- Material library creation (coordinate with team)
- Final presentation preparation
- **Final** (Dec 7): Submission ready

### Development Flow

```
Week 1: CPU Infrastructure
    ↓
RMIP Builder → Vulkan Resources → GPU Upload
    ↓
Week 2: GPU Shaders
    ↓
Intersection Shader → Inverse Mapping → Ray Utilities
    ↓
Week 3: Integration
    ↓
RMIP Traversal → BLAS/SBT → First Intersection
    ↓
Week 4: Optimization
    ↓
Texel Marching → Performance Tuning → Multi-Material
    ↓
Week 5: Finalization
    ↓
Documentation → Material Library → Submission
```

---

## Development Phases

### Phase 1: CPU Infrastructure Foundation (Week 1: Nov 3-9)
**Goal**: Build RMIP data structure and resource management

**Tasks**:
- [x] Environment setup and build verification (Nov 1)
- [ ] RMIP data structure design (`src/rmip_builder.hpp`)
- [ ] Basic RMIP builder implementation (min-max pyramid)
- [ ] Unit tests for RMIP builder
- [ ] Vulkan buffer creation for RMIP data
- [ ] GPU upload and validation

**Checkpoint** (End of Week 1):
- [ ] RMIP builder working for 256×256 test texture
- [ ] RMIP data successfully uploaded to GPU
- [ ] CPU-side query function working

---

### Phase 2: GPU Shader Foundation (Week 2: Nov 10-16)
**Goal**: Implement shader infrastructure and inverse mapping

**Tasks**:
- [ ] Create `shaders/rmip_intersection.slang` skeleton
- [ ] Create `shaders/rmip_common.h.slang` utilities
- [ ] Implement ray-triangle intersection (object space)
- [ ] Implement barycentric coordinate computation
- [ ] Implement triangle interpolation functions
- [ ] Implement inverse displacement mapping (Newton solver)
- [ ] Custom intersection shader API integration

**Milestone 1** (Nov 12):
- [ ] Present RMIP foundation work to team
- [ ] Demo: RMIP data visualization
- [ ] Custom intersection shader compiling

**Checkpoint** (End of Week 2):
- [ ] Inverse displacement mapping working
- [ ] Shader utilities tested and validated
- [ ] Ready for full traversal integration

---

### Phase 3: Core Traversal & Integration (Week 3: Nov 17-23)
**Goal**: Implement full RMIP traversal and first intersection

**Tasks**:
- [ ] RMIP query function (shader-side rectangular region lookup)
- [ ] 3D bounding box computation from displacement bounds
- [ ] Hierarchical traversal loop (stack-based)
- [ ] BLAS modification (triangles → AABBs)
- [ ] SBT setup for custom intersection shader
- [ ] glTF extension parser for displacement
- [ ] First end-to-end intersection test

**Milestone 2** (Nov 24):
- [ ] Full RMIP pipeline working (builder → traversal → intersection)
- [ ] At least 2 test scenes with displacement
- [ ] Performance comparison vs. baseline

---

### Phase 4: Texel Marching & Optimization (Week 4: Nov 24-30)
**Goal**: Implement texel marching and performance tuning

**Tasks**:
- [ ] Texel marching algorithm
- [ ] Implicit ray projection form
- [ ] Turning point computation
- [ ] Front-to-back traversal ordering
- [ ] GPU profiling integration (Nsight)
- [ ] Shader divergence reduction
- [ ] Adaptive marching threshold
- [ ] Texture coordinate tiling support
- [ ] Multi-material scene support
- [ ] Memory optimization (RMIP compression)

**Milestone 3** (Dec 1):
- [ ] 3+ materials with RMIP displacement
- [ ] Performance targets met (30+ FPS at 1080p)
- [ ] Comparison modes (RMIP on/off toggle)

---

### Phase 5: Polish & Documentation (Week 5: Dec 1-7)
**Goal**: Finalize for submission

**Tasks**:
- [ ] Code cleanup and comprehensive documentation
- [ ] Build instructions and README updates
- [ ] Shader code comments and documentation
- [ ] Known limitations documentation
- [ ] Performance data collection and analysis
- [ ] Visual quality comparison renders
- [ ] Material library coordination with team
- [ ] Final presentation slides (RMIP sections)
- [ ] Demo video recording (RMIP portions)

**Final Deliverable** (Dec 7):
- [ ] All RMIP code merged and tested
- [ ] RMIP documentation complete
- [ ] Presentation materials ready

---

## Week-by-Week Schedule

### Week 1: Nov 3-9 (CPU Infrastructure)

**Goal**: Build RMIP data structure and resource management

**Monday Nov 4**:
- [ ] Create `src/rmip_builder.hpp` with data structure definitions
- [ ] Stub out `RMIPBuilder` class interface
- [ ] Design RMIP hierarchy format

**Tuesday Nov 5**:
- [ ] Implement basic min-max mipmap builder (square regions only)
- [ ] Test with 256×256 test texture (checkerboard pattern)
- [ ] Verify min/max values are correct (unit test)

**Wednesday Nov 6** (Team Integration):
- [ ] Extend to rectangular regions (power-of-two dimensions)
- [ ] Implement RMIP query function (CPU-side test)
- [ ] Present progress to team

**Thursday Nov 7**:
- [ ] Create Vulkan buffer for RMIP data
- [ ] Upload RMIP data to GPU
- [ ] Bind RMIP buffer to shader descriptors

**Friday Nov 8**:
- [ ] Implement glTF displacement texture loading
- [ ] Hook RMIP builder into scene loading pipeline
- [ ] Test with sample model + custom displacement

**Saturday Nov 9**:
- [ ] Document Week 1 progress
- [ ] Code cleanup and comments
- **Checkpoint**: RMIP builder working, data on GPU

---

### Week 2: Nov 10-16 (GPU Shaders & Inverse Mapping)

**Goal**: Implement shader infrastructure and inverse displacement

**Sunday Nov 10**:
- [ ] Create `shaders/rmip_intersection.slang` skeleton
- [ ] Create `shaders/rmip_common.h.slang` for utilities
- [ ] Implement basic ray-triangle intersection (object space)

**Monday Nov 11**:
- [ ] Implement barycentric coordinate computation
- [ ] Implement triangle interpolation functions
- [ ] Unit test interpolation functions

**Tuesday Nov 12** (Milestone 1 + Team Integration):
- [ ] **MILESTONE 1 PRESENTATION** - Demo RMIP builder and initial shaders
- [ ] Coordinate with Person B (Quad LDS) on sampling integration
- [ ] Coordinate with Person C (Materials) on BRDF requirements

**Wednesday Nov 13**:
- [ ] Study custom intersection shader API
- [ ] Create minimal intersection shader (basic hit reporting)
- [ ] Test that shader compiles and loads

**Thursday Nov 14**:
- [ ] Begin inverse displacement mapping
- [ ] Implement initial guess (project to base plane)
- [ ] Implement Newton iteration (1-2 iterations first)

**Friday Nov 15**:
- [ ] Complete inverse displacement (full Newton solver)
- [ ] Test convergence on various triangle shapes
- [ ] Handle edge cases (ray misses, convergence failure)

**Saturday Nov 16**:
- [ ] Document Week 2 progress
- [ ] Code cleanup and shader comments
- **Checkpoint**: Inverse displacement working, shaders ready for traversal

---

### Week 3: Nov 17-23 (Core Traversal & Integration)

**Goal**: Implement full RMIP traversal and first intersection

**Sunday Nov 17**:
- [ ] Implement RMIP query function in shader
- [ ] Sample RMIP buffer for rectangular region
- [ ] Return min/max displacement

**Monday Nov 18**:
- [ ] Implement 3D bounding box computation
- [ ] Sample base triangle at UV rectangle corners
- [ ] Expand/contract by displacement bounds

**Tuesday Nov 19** (Team Integration):
- [ ] Implement 2D bound subdivision (split along longer axis)
- [ ] Implement hierarchical traversal loop (stack-based)
- [ ] Test with team's Quad LDS integration

**Wednesday Nov 20**:
- [ ] Modify BLAS creation for AABB geometry
- [ ] Handle mixed geometry (triangular + AABB)
- [ ] Verify acceleration structure builds correctly

**Thursday Nov 21**:
- [ ] Implement SBT setup for custom intersection shader
- [ ] Create hit group with intersection shader
- [ ] Test ray tracing pipeline invokes shader

**Friday Nov 22**:
- [ ] First end-to-end intersection test
- [ ] Debug intersection issues
- [ ] Verify displaced surface is visible

**Saturday Nov 23**:
- [ ] Prepare Milestone 2 demo and slides
- [ ] Document Week 3 progress
- **Deliverable**: First successful RMIP intersection

---

### Week 4: Nov 24-30 (Texel Marching & Optimization)

**Goal**: Implement texel marching and performance tuning

**Sunday Nov 24**:
- [ ] **MILESTONE 2 PRESENTATION**
- [ ] Implement implicit ray projection form
- [ ] Test zero-crossing detection

**Monday Nov 25**:
- [ ] Implement turning point computation
- [ ] Split initial ray projection at turning points
- [ ] Implement texel marching algorithm

**Tuesday Nov 26** (Team Integration):
- [ ] Determine ray exit edge per texel
- [ ] March through texels until hit or exit
- [ ] Test with team's material system

**Wednesday Nov 27** (Thanksgiving - Light Work):
- [ ] GPU profiling integration (Nsight)
- [ ] Analyze shader performance
- [ ] Document optimization opportunities

**Thursday Nov 28** (Thanksgiving):
- [ ] (Off day)

**Friday Nov 29**:
- [ ] Optimize traversal (reduce divergence)
- [ ] Implement adaptive marching threshold
- [ ] Test different stack sizes

**Saturday Nov 30**:
- [ ] Memory bandwidth optimization
- [ ] Texture coordinate tiling support
- [ ] Multi-material scene support
- **Deliverable**: Texel marching working, performance improved

---

### Week 5: Dec 1-7 (Polish & Documentation)

**Goal**: Finalize for submission

**Sunday Dec 1**:
- [ ] **MILESTONE 3 PRESENTATION**
- [ ] Prepare Milestone 3 demo: 3+ materials

**Monday Dec 2**:
- [ ] Code cleanup and comprehensive documentation
- [ ] Shader code comments and explanations
- [ ] Known limitations documentation

**Tuesday Dec 3** (Team Integration):
- [ ] Material library coordination with team
- [ ] Test integration with Bounded VNDF and Fast-MSX
- [ ] Final code review with team

**Wednesday Dec 4**:
- [ ] Build instructions and README updates
- [ ] Performance data collection and analysis
- [ ] Create comparison scenes (RMIP vs. baseline)

**Thursday Dec 5**:
- [ ] Demo video recording (RMIP portions)
- [ ] Screenshot collection
- [ ] Visual quality comparison renders

**Friday Dec 6**:
- [ ] Final presentation slides (RMIP sections)
- [ ] Practice presentation with team
- [ ] Final testing and validation

**Saturday Dec 7**:
- [ ] Package submission materials
- [ ] **FINAL PROJECT DUE (end of day)**
- [ ] Submit all materials

**Sunday Dec 8**:
- [ ] **FINAL PRESENTATION DUE (4pm)**
- [ ] **LIVE PRESENTATION (5:30pm)**

---

## Detailed Task Breakdown

### Task 1: RMIP Data Structure Builder (CPU-Side)

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

### Task 2: Inverse Displacement Mapping (GPU-Side)

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

### Task 3: RMIP Traversal (GPU-Side)

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

### Task 4: Texel Marching (GPU-Side)

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

### Task 5: BLAS/SBT Setup (CPU-Side)

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

### Checkpoint 1: Data Flow Validation (End of Week 1 - Nov 9)

**Test**: Verify CPU → GPU data transfer

**Steps**:
1. Build RMIP for 256×256 checkerboard pattern
2. Upload RMIP data to GPU buffer
3. Create test shader that samples RMIP
4. Visualize RMIP min/max as color (red=min, green=max)
5. Verify output image looks correct

**Success Criteria**:
- [ ] RMIP data uploads correctly (no corruption)
- [ ] Shader can read RMIP buffer
- [ ] Visualization matches expected pattern

---

### Checkpoint 2: Inverse Mapping Working (End of Week 2 - Nov 16)

**Test**: Verify inverse displacement mapping converges

**Setup**:
- Simple test triangle with known displacement
- Test points at various 3D positions

**Steps**:
1. Implement full Newton iteration (5 iterations)
2. Test convergence on flat triangles (should converge in 3-5 iterations)
3. Test convergence on curved triangles
4. Handle edge cases (ray misses, non-convergence)

**Success Criteria**:
- [ ] Inverse mapping converges correctly
- [ ] UV coordinates are accurate
- [ ] Edge cases handled gracefully

---

### Checkpoint 3: First Intersection (End of Week 3 - Nov 23)

**Test**: Intersect a single displaced plane

**Setup**:
- Simple scene: One quad with sine wave displacement
- Camera: Looking straight at quad
- Expected: See wavy surface

**Steps**:
1. Create AABB for quad
2. Implement basic traversal (no optimizations yet)
3. Run path tracer, check for hits
4. Debug intersection issues

**Success Criteria**:
- [ ] Ray-AABB intersection works
- [ ] Custom intersection shader is invoked
- [ ] Displaced surface is visible (even if slow)
- [ ] UVs and normals computed correctly

---

### Checkpoint 4: Performance Baseline (End of Week 4 - Nov 30)

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
1. Integrate Nsight profiler
2. Add performance counters to shader
3. Run benchmark scenes
4. Identify bottlenecks

**Success Criteria**:
- [ ] Profiler working correctly
- [ ] Can measure per-component time
- [ ] Have baseline data for optimization

---

## Testing Strategy

### Unit Tests (Continuous)

**CPU-Side Tests**:
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

**GPU-Side Tests**:
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

**RMIP Foundation**:
- [x] Repository cloned and build verified (Nov 1)
- [ ] RMIP builder implemented and tested
- [ ] RMIP data uploaded to GPU
- [ ] Basic AABB geometry created
- [ ] Custom intersection shader compiling
- [ ] Ray-triangle utilities implemented
- [ ] Basic inverse mapping working

**Team Deliverables**:
- [ ] Present RMIP progress to team (5 minutes)
- [ ] Demo: Visualize RMIP data
- [ ] Coordinate with Person B (Quad LDS) and Person C (Materials)

---

### Milestone 2 (Nov 24)

**RMIP Core Implementation**:
- [ ] glTF displacement loading
- [ ] SBT setup complete
- [ ] Full RMIP traversal working
- [ ] First successful intersection
- [ ] 2+ test scenes with displacement
- [ ] Performance profiling integrated

**Team Deliverables**:
- [ ] Performance comparison: RMIP vs. baseline (FPS, memory)
- [ ] Present to team (10 minutes)
- [ ] Demo: Interactive scene with displacement
- [ ] Integration with Quad LDS sampling

---

### Milestone 3 (Dec 1)

**RMIP Production Features**:
- [ ] Texel marching implemented
- [ ] Quality tuning complete
- [ ] Shader performance optimized
- [ ] 3+ materials with RMIP displacement
- [ ] Memory optimization complete
- [ ] All shader code documented
- [ ] Known limitations documented

**Team Deliverables**:
- [ ] Benchmarks: FPS at different resolutions
- [ ] Present to team (10 minutes)
- [ ] Demo: Material showcase scene
- [ ] Material library contribution (coordinate with team)

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

### Team Standup (Discord/Slack - Mon/Wed/Fri)

**Format**:
```
**Person A (RMIP)** - [Date]
✅ Progress: Implemented RMIP builder base class
🎯 Today: Add compression support and GPU upload
🚧 Blockers: None
🔗 Dependencies: Will need Quad LDS integration next week

**Person B (Quad LDS)** - [Date]
[Their update]

**Person C (Bounded VNDF + Fast-MSX)** - [Date]
[Their update]
```

---

### Team Integration Session Notes

**Format**:
```
**Team Integration Session** - [Date]
📌 Goal: Test all 4 techniques together
✅ Completed:
  - RMIP displacement working with Quad LDS sampling
  - Bounded VNDF integrated with material system
✅ Person A (RMIP):
  - RMIP buffer uploads correctly
  - Custom intersection shader invoked
📋 Next Steps:
  - Person A: Add tiling support for materials
  - Team: Test multi-material scene
🗓️ Next Session: [Date + 3 days]
```

---

### Personal Progress Tracking

**Format**:
```
**RMIP Progress Log** - Week [X]

**Completed This Week**:
- [x] Task 1
- [x] Task 2

**In Progress**:
- [ ] Task 3 (50% complete)

**Blocked/Issues**:
- Issue: Inverse mapping convergence on curved surfaces
- Solution: Implementing better initial guess

**Next Week Goals**:
- [ ] Complete traversal algorithm
- [ ] First intersection test
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

This implementation plan provides a **structured roadmap** for implementing RMIP as a single developer within the 3-person MatForge team over 5 weeks. Key features:

✅ **Full-Stack Ownership**: Complete CPU and GPU implementation by Person A
✅ **Sequential Development**: Week 1 (CPU), Week 2 (GPU), Weeks 3-5 (Integration & Optimization)
✅ **Team Integration**: Clear coordination points with Person B (Quad LDS) and Person C (Materials)
✅ **Integration Checkpoints**: 4 major checkpoints to verify progress
✅ **Risk Mitigation**: Fallback plans for each major risk
✅ **Detailed Tasks**: 5 core tasks with code snippets and acceptance criteria
✅ **Weekly Schedule**: Day-by-day breakdown for all 5 weeks

**Next Steps for Person A**:
1. Review this plan and customize to personal working style
2. Set up communication with teammates (Discord, GitHub, etc.)
3. Begin Week 1 tasks (RMIP builder - CPU infrastructure)
4. Attend team standups Mon/Wed/Fri
5. Participate in team integration sessions Tuesdays

**Team Context**:
- **Person A (You)**: RMIP displacement ray tracing (~800 LOC)
- **Person B**: Quad LDS sampling (~400 LOC)
- **Person C**: Bounded VNDF + Fast-MSX (~350 LOC)
- **Total**: Complete 4-paper integrated system

**Remember**: This is a living document. Update as you learn and adapt! Communicate blockers early and leverage team expertise when needed.

---

**Document Version**: 2.0 (Single-Person Workflow)
**Created**: November 1, 2025
**Updated for Single-Person**: November 4, 2025
**Author**: MatForge Person A (RMIP Specialist)
**Team**: 3-person MatForge team (CIS 5650 Fall 2025)
