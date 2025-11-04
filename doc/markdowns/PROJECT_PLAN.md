# MatForge: Advanced Material Rendering System

**Project Name**: MatForge
**Date**: November 3, 2025 (Post-Pitch Update)
**Status**: ✅ **APPROVED - IMPLEMENTATION PHASE**
**Team**: 3 students | **Timeline**: Nov 3 - Dec 7, 2025 (5 weeks)

---

## Executive Summary

**PROJECT: MatForge - Production-Quality Advanced Material Rendering System**

After successful pitch and positive feedback, the project now includes **THREE complementary papers**:

### Team Division
- **Person A**: RMIP (Displacement Ray Tracing)
- **Person B**: Quad-Optimized Low-Discrepancy Sequences (Sampling Foundation)
- **Person C**: Bounded VNDF + Fast-MSX (Efficient Sampling + Multiple Scattering)

### Why This Structure Works
✅ **Addresses "Too Easy" Feedback** - Three substantial papers, each person has ownership
✅ **Thematic Unity** - All three focus on advanced material rendering
✅ **Complementary Stack** - Each layer builds on the others:
  - **Foundation**: Quad LDS (better random numbers for everyone)
  - **Geometry**: RMIP (displacement detail)
  - **Materials**: Bounded VNDF (efficient sampling) + Fast-MSX (realistic scattering)
✅ **Clear Division** - Minimal dependencies, parallel development possible
✅ **Production Focus** - Complete pipeline from sampling to shading

**Pitch Result**: Approved with enthusiasm. Feedback emphasized measuring impact of each component.

---

## Paper 1: RMIP - Displacement Ray Tracing

**Full Title**: "RMIP: Displacement ray-tracing via inversion and oblong bounding"
**Authors**: Théo Thonat, Iliyan Georgiev, François Beaune, Tamy Boubekeur (Adobe)
**Published**: SIGGRAPH Asia 2023
**DOI**: https://doi.org/10.1145/3610548.3618182

### What It Does

RMIP enables **tessellation-free displacement mapping** for GPU ray tracing. Instead of pre-tessellating displaced geometry into millions of triangles, it ray-traces displacement maps **directly** using a novel data structure.

**Key Innovation**: Combines **inverse displacement mapping** with **oblong (rectangular) bounding** in texture space to efficiently find ray-surface intersections.

### Core Algorithm

1. **Pre-process**: Build RMIP data structure - min/max displacement bounds over **rectangular regions** in texture space (like MIP maps, hence "RMIP")
2. **Runtime**: When ray hits base triangle with displacement:
   - Project ray into texture space (inverse mapping)
   - Hierarchically narrow down texture-space region using RMIP bounds
   - "Ping-pong" between 2D texture bounds and 3D object bounds
   - Final step: March through texels, generate micro-geometry on-the-fly
   - Intersect with displaced surface

### Performance Results

**From paper Figure 1**:
- **11× faster** than previous state-of-the-art (TFDM)
- **3× less memory** than tessellation approach
- Maintains **full geometric accuracy** (no tessellation artifacts)

**Typical performance**:
- 4K displacement maps with high-frequency detail
- Real-time path tracing feasible (10-30 FPS at 1080p)
- Works with tiled displacement maps

### What Makes It Significant

1. **Memory Efficiency**: No need to store tessellated geometry
   - 4K displacement map: ~16MB texture vs. ~500MB+ tessellated mesh

2. **Quality**: Pixel-perfect accuracy at all distances
   - No popping from LOD transitions
   - No tessellation undersampling artifacts

3. **Flexibility**: Dynamic displacement content
   - Can change displacement maps at runtime
   - Tiling works naturally

4. **GPU-Friendly**: Leverages hardware ray tracing (TLAS/BLAS)
   - Custom intersection shaders
   - Per-ray independent traversal

### Technical Requirements

**Pre-processing**:
- Build RMIP hierarchy: ~1-2 seconds for 4K map
- Storage: ~2× texture size (extra channel for min/max)

**Runtime (per ray intersection)**:
- ~15-20 texture lookups (hierarchical traversal)
- ~10-50 micro-triangle generations (final march)
- Custom intersection shader (~200 lines of code)

**Integration Points**:
- Vulkan ray tracing pipeline (VK_KHR_ray_tracing_pipeline)
- Custom intersection shaders (VK_KHR_ray_tracing_maintenance1)
- Descriptor indexing for texture access

---

## Paper 2: Fast-MSX - Multiple Scattering Approximation

**Full Title**: "Fast-MSX: Fast Multiple Scattering Approximation"
**Authors**: (From SIGGRAPH 2023)
**Published**: SIGGRAPH 2023

### What It Does

Fast-MSX adds **second-bounce light transport** to microfacet BRDFs (like GGX/Cook-Torrance) using a **closed-form analytical solution**. This makes rough materials look more realistic without expensive Monte Carlo sampling.

**Key Innovation**: Uses **relaxed V-cavity model** with **horizontal bounce constraint** to derive a simple additive BRDF term that captures multiple scattering.

### The Problem It Solves

Standard microfacet models (GGX) assume **single-bounce lighting**:
- Light hits microfacet → bounces to viewer
- **Energy loss**: Light that bounces multiple times within microstructure is ignored
- **Result**: Rough materials appear too dark (especially at grazing angles)
- **Error increases**: Higher roughness = more energy loss

### Core Algorithm

**Standard BRDF**:
```
f(v, l) = (D × G × F) / (4(c · v)(c · l))
```

**Fast-MSX Addition**:
```
f_total = f_single-scatter + f_multi-scatter

where f_multi-scatter = (D_I × G_I × F_I) / (2(c · v))
```

**Computation** (Algorithm 1, ~20 lines):
1. Compute cavity orientation: `c = normalize(h + n)` (2 ops)
2. Compute geometry term `G_I` using relaxed V-cavity (6 ops)
3. Compute distribution term `D_I` using modified GGX (3 ops)
4. Compute Fresnel term `F_I = F²` (1 op)
5. Combine and add to single-scatter term

**Total Cost**: ~12 operations (~5% overhead vs. standard GGX)

### Performance Results

**Render Time** (128×128 image, 512 spp, Mitsuba):
- **GGX alone**: ~40 seconds
- **Fast-MSX**: ~42 seconds **(+5% overhead)**
- **Heitz et al. (stochastic)**: ~80 seconds **(2× slower)**
- **Wang et al. (path integral)**: ~60 seconds **(1.5× slower)**

**Quality** (MSE vs. ground truth):
- At α=0.3 (moderate roughness): **10× better than GGX**
- At α=0.7 (high roughness): **100× better than GGX**
- Similar quality to stochastic methods, but deterministic (no noise)

**Real-Time Feasibility**:
- Successfully runs in WebGL (Shadertoy demo)
- Successfully integrated into O3DE game engine
- Negligible performance impact

### What Materials Benefit Most

**Best results** (α = 0.3 to 0.9):
- Rough metals (gold, copper, aluminum)
- Rough dielectrics (concrete, stone, ceramics)
- Fabrics (not translucent materials - those aren't covered)

**Visual improvements**:
- More saturated colors for metals
- Proper energy conservation at grazing angles
- Smoother appearance (no darkening artifacts)

### Limitations

- ❌ Not energy-conserving (fails furnace test)
- ❌ Not reciprocal (f(v,l) ≠ f(l,v))
- ❌ Only supports reflective materials (no transmission)
- ✅ But: Visually close to ground truth for typical roughness

## Paper 3: Quad-Optimized Low-Discrepancy Sequences (NEW)

**Full Title**: "Quad-Optimized Low-Discrepancy Sequences"
**Authors**: Victor Ostromoukhov, Nicolas Bonneel, David Coeurjolly, Jean-Claude Iehl
**Published**: SIGGRAPH 2024
**DOI**: https://dl.acm.org/doi/10.1145/3641519.3657431
**GitHub**: https://github.com/liris-origami/Quad-Optimized-LDS

### What It Does

Improves upon Sobol' sequences (the gold standard for Monte Carlo rendering) by optimizing sample uniformity in **consecutive 2D and 4D projections**. Critical for path tracing where you need correlated random numbers for BRDF + light + continuation decisions.

**Key Innovation**: Base-3 Sobol' construction with optimized generator matrices, producing **(1,4)-sequences** in all consecutive quadruplets of dimensions.

### Why It's Relevant

✅ **Foundation for Everything** - Better sampling helps RMIP, Bounded VNDF, Fast-MSX equally
✅ **Production-Proven** - Beats industry-standard Sobol' sequences
✅ **Implementation Available** - Open-source reference code on GitHub
✅ **Measurable Impact** - Convergence rate improvements across entire renderer

### Performance Characteristics

**Advantages over Sobol'**:
- Better uniformity in consecutive 4D projections (critical for BRDF+light sampling)
- Faster convergence (fewer samples for equal quality)
- Same practical benefits: sequences, arbitrary dimensions, fast, compact

**Implementation Complexity**:
- Pre-compute: Generate polynomial tables (use provided code)
- Runtime: Fast bit operations (similar to Sobol')
- Memory: Small lookup tables (~few KB)

### Integration Points

**Where it fits**: Replace random number generator used by path tracer
- `shaders/gltf_pathtrace.slang` - Replace Sobol'/PCG sampler
- Host-side: Pre-compute generator matrices (one-time setup)
- Device-side: Sampling function in shader

**Estimated LOC**: ~300-400 lines (100 C++ host, 150 GLSL device, 150 utilities)

---

## Paper 4: Bounded VNDF Sampling for Smith-GGX (NEW)

**Full Title**: "Bounded VNDF Sampling for the Smith-GGX BRDF"
**Authors**: Yusuke Tokuyoshi, Kenta Eto (AMD)
**Published**: SIGGRAPH Asia 2023 / I3D 2024
**DOI**: https://dl.acm.org/doi/10.1145/3651291
**PDF**: https://gpuopen.com/download/publications/Bounded_VNDF_Sampling_for_Smith-GGX_Reflections.pdf

### What It Does

Improves the standard VNDF (Visible Normal Distribution Function) sampling method for GGX microfacet materials by **bounding the sampling range** to eliminate invalid samples that would be occluded by the surface.

**Key Innovation**: Uses spherical cap-based bounding instead of hemisphere sampling, reducing rejected samples by up to 40% for rough surfaces.

### Why It's Perfect for This Project

✅ **Complements Fast-MSX** - Both focus on material appearance, work in same pipeline stage
✅ **Uses Quad LDS** - Benefits directly from better random number generation
✅ **Low Complexity** - Drop-in replacement for existing GGX sampler (~200 lines)
✅ **Production Proven** - AMD research, being integrated into Blender
✅ **Measurable Impact** - Clear variance reduction graphs

### Performance Characteristics

**Benefits**:
- 15-40% variance reduction for rough materials (α > 0.5)
- Most effective at low-medium roughness (α < 0.5)
- Negligible computational overhead
- Unbiased sampling (maintains correctness)

### Integration with Fast-MSX

**No Interference** - They operate at different stages:
- **Bounded VNDF**: Direction generation (importance sampling)
- **Fast-MSX**: BRDF evaluation (shading computation)
- **Integration**: Sample using Bounded VNDF, evaluate with Fast-MSX

**Pipeline**: `Quad LDS → Bounded VNDF → Fast-MSX → Output`

### Integration Points

**Where it fits**: Replace GGX sampling function
- `shaders/pbr_material_eval.h.slang` - Replace `SampleGGXVNDF()` function
- Add spherical cap computation (~50 lines)
- Update PDF computation (~30 lines)

**Estimated LOC**: ~200 lines (all GLSL shader code)

---

## How All Four Papers Work Together

### Unified Material Rendering Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                     MatForge Pipeline                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. QUAD LDS (Person B)                                    │
│     └─ Generate high-quality random numbers                │
│        ↓                                                    │
│  2. RAY-SURFACE INTERSECTION                               │
│     └─ RMIP (Person A): Displacement ray tracing           │
│        ↓                                                    │
│  3. DIRECTION SAMPLING                                      │
│     └─ Bounded VNDF (Person C): Efficient importance sample│
│        ↓                                                    │
│  4. BRDF EVALUATION                                         │
│     └─ Fast-MSX (Person C): Multiple scattering            │
│        ↓                                                    │
│  5. MONTE CARLO INTEGRATION                                 │
│     └─ Combine: f(ωᵢ, ωₒ) × L(ωₒ) × cos(θ) / PDF         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Why This is a Complete System

| Component | Contribution | Person | Dependencies |
|-----------|-------------|--------|--------------|
| **Quad LDS** | Better random numbers | B | None |
| **RMIP** | Geometric detail (displacement) | A | Quad LDS (minimal) |
| **Bounded VNDF** | Efficient sampling | C | Quad LDS |
| **Fast-MSX** | Optical realism (scattering) | C | Bounded VNDF |

**Key Insight**: Clean dependency chain allows parallel development with late integration.

---

## Base Repository Analysis: vk_gltf_renderer

**Repository**: https://github.com/nvpro-samples/vk_gltf_renderer
**Version**: 2.0 (2023-2025)
**Framework**: Built on nvpro-core2 (NVIDIA Professional Graphics Samples)

### Why This Is An Excellent Foundation

#### ✅ 1. Complete Vulkan Ray Tracing Infrastructure

**Already Implemented**:
- Full ray tracing pipeline (VK_KHR_ray_tracing_pipeline)
- TLAS/BLAS acceleration structures with dynamic updates
- Custom shader support (Slang compilation)
- Ray generation, closest-hit, miss shaders fully functional
- Descriptor set management for textures and materials

**What This Means**:
- Don't need to build ray tracing from scratch
- Can focus on RMIP custom intersection shader
- Existing pipeline handles complexity

#### ✅ 2. Production-Quality Path Tracer

**Current Features**:
- Monte Carlo path tracing with global illumination
- Multiple importance sampling (lights + environment)
- Progressive rendering with temporal coherence
- Adaptive sampling (Interactive/Balanced/Quality modes)
- Denoising support (optional DLSS Ray Reconstruction)

**What This Means**:
- Already a "complete renderer" - just extending it
- Performance infrastructure in place
- Can measure Fast-MSX impact accurately

#### ✅ 3. Comprehensive Material System

**Current Material Support**:
- Full PBR material evaluation (base color, metallic, roughness)
- 13 glTF material extensions (anisotropy, clearcoat, transmission, etc.)
- Texture sampling with mip-mapping
- BSDF evaluation in `pbr_material_eval.h.slang`

**What This Means**:
- Material evaluation pipeline ready for Fast-MSX integration
- Can extend existing BSDF functions
- Testing framework in place (compare with/without Fast-MSX)

#### ✅ 4. Modern Shader System (Slang)

**Advantages**:
- Hot-reload shaders (F5 key) for rapid iteration
- Modular shader architecture (separate files per feature)
- Cross-compilation to SPIR-V
- Debug symbols and error reporting

**What This Means**:
- Fast development iteration
- Can test RMIP and Fast-MSX independently
- Easy to compare implementations

#### ✅ 5. Performance Profiling Built-In

**Existing Tools**:
- GPU profiler (ProfilerGpuTimer)
- Frame timing display
- Memory usage tracking
- Per-pass performance breakdown

**What This Means**:
- Can measure RMIP intersection cost
- Can measure Fast-MSX BRDF overhead
- Can generate performance graphs for final presentation

#### ✅ 6. glTF 2.0 Scene Support

**Benefits**:
- Industry-standard asset format
- Rich material test scenes available
- Texture support (base color, normal, displacement, roughness, etc.)
- Can showcase on standard benchmarks

**What This Means**:
- Don't need to write custom asset loader
- Can use public test scenes
- Easy to share results

### Repository Structure

```
vk_gltf_renderer/
├── src/
│   ├── renderer.cpp/hpp              - Main coordinator
│   ├── renderer_pathtracer.cpp/hpp   - Ray tracing implementation ← RMIP goes here
│   ├── renderer_rasterizer.cpp/hpp   - Rasterization (optional)
│   ├── resources.hpp                 - Central resource manager
│   └── ui_renderer.cpp               - UI and settings
├── shaders/
│   ├── gltf_pathtrace.slang          - Path tracer main shader ← RMIP + Fast-MSX go here
│   ├── get_hit.h.slang               - Hit state computation ← RMIP integration
│   ├── pbr_material_eval.h.slang     - BSDF evaluation ← Fast-MSX goes here
│   └── shaderio.h                    - Host-device structures
└── CMakeLists.txt                    - Build configuration
```

### Integration Points

#### For RMIP (Displacement Ray Tracing)

**Files to Modify**:
1. `shaders/gltf_pathtrace.slang` - Add custom intersection shader
2. `shaders/get_hit.h.slang` - Extend HitState with displacement data
3. `src/renderer_pathtracer.cpp` - Add RMIP data structure management

**New Files to Add**:
1. `shaders/rmip_intersection.h.slang` - RMIP traversal algorithm
2. `shaders/rmip_common.h.slang` - Inverse mapping utilities
3. `src/rmip_builder.cpp` - Pre-process displacement maps into RMIP

**Estimated LOC**: ~800 lines (400 shader, 400 C++)

#### For Fast-MSX (Multiple Scattering)

**Files to Modify**:
1. `shaders/pbr_material_eval.h.slang` - Add Fast-MSX BRDF term
2. `shaders/gltf_pathtrace.slang` - Call Fast-MSX in path tracer

**New Files to Add**:
1. `shaders/fastmsx.h.slang` - Fast-MSX BRDF evaluation

**Estimated LOC**: ~150 lines (mostly shader code)

### Comparison to SurfelPlus Approach

**SurfelPlus** (Last year's SIGGRAPH project):
- Forked from `vk_raytrace` (older nvpro sample)
- Added surfel GI system (6 passes)
- Novel reflection acceleration
- Result: SIGGRAPH 2025 acceptance

**Our Approach** (RMIP + Fast-MSX):
- Fork from `vk_gltf_renderer` (newer, more complete)
- Add displacement ray tracing (RMIP) + multi-scatter BRDF (Fast-MSX)
- Novel combination + Vulkan optimizations
- Goal: Production-quality material system

**Key Difference**: We're starting with a more mature base, which allows us to focus on the novel techniques rather than infrastructure.

---

## Final Deliverables

### Milestone 1 (Nov 12): Individual Technique Foundations

**Person A - RMIP Implementation**:
- ✅ RMIP data structure builder (pre-process displacement maps)
- ✅ Custom intersection shader (basic version)
- ✅ Ray-to-texture-space projection (inverse mapping)
- ✅ Simple test scene: 1 displaced plane with height map
- ✅ Metrics: Traversal steps, intersection cost

**Person B - Quad LDS Implementation**:
- ✅ Host-side generator matrix construction (base-3 Sobol')
- ✅ Device-side sampling function (GLSL)
- ✅ Integration into path tracer random number pipeline
- ✅ Discrepancy analysis and validation
- ✅ Metrics: Convergence rate vs. Sobol'/PCG

**Person C - Bounded VNDF Implementation**:
- ✅ Spherical cap bounding for GGX sampling
- ✅ Modified `SampleGGXVNDF()` function
- ✅ PDF computation for bounded sampling
- ✅ Test scene: Spheres with varying roughness (α = 0.1 to 0.9)
- ✅ Metrics: Rejection rate reduction vs. standard VNDF

**Demo**:
- Three individual demos showing each technique working
- Initial metrics and performance data

### Milestone 2 (Nov 24): Integration & Material System

**Combined Pipeline**:
- ✅ All four techniques working together: Quad LDS → RMIP → Bounded VNDF → Fast-MSX
- ✅ Fast-MSX BRDF evaluation integrated with Bounded VNDF sampling
- ✅ Material library: 7+ materials
  - Rough stone (displacement + high roughness)
  - Hammered copper (displacement + metallic scattering)
  - Wood planks (displacement + anisotropic roughness)
  - Concrete (displacement + medium roughness)
  - Velvet/fabric (high roughness, no displacement - showcase Fast-MSX)
  - Ceramic (low-medium roughness + displacement)
  - Brick wall (tiled displacement)

**Performance Optimization**:
- ✅ RMIP: Hierarchical traversal, adaptive texel marching
- ✅ Quad LDS: Optimized device-side sampling
- ✅ Bounded VNDF: Spherical cap efficiency
- ✅ Fast-MSX: Roughness-dependent early exit

**Demo**:
- Multi-material showcase scene
- Interactive parameter editor (displacement scale, roughness, metallic)
- Comparison modes (toggle each technique on/off)
- Performance overlay (FPS, cost breakdown)

**Metrics**:
- RMIP: Memory usage, traversal cost, FPS impact
- Quad LDS: Convergence improvement, sample quality
- Bounded VNDF: Rejection rate reduction
- Fast-MSX: MSE vs. ground truth, energy conservation
- Combined: FPS at 1080p, 1440p, 2160p

### Milestone 3 (Dec 1): Production Features & Analysis

**Advanced Features**:
- ✅ Material editor with live preview (all parameters adjustable)
- ✅ Comparison modes for all four techniques:
  - Toggle Quad LDS (vs. Sobol'/PCG)
  - Toggle RMIP (vs. tessellation/parallax mapping)
  - Toggle Bounded VNDF (vs. standard VNDF)
  - Toggle Fast-MSX (vs. standard GGX)
- ✅ Material presets and gallery
- ✅ Export functionality (JSON, glTF extensions)

**Multiple Test Scenes**:
- ✅ Material showcase scene (all 7+ materials)
- ✅ Performance stress test scene
- ✅ Quality comparison scene (close-up detail)
- ✅ Real-world architectural scene

**Comprehensive Benchmark Suite**:
- ✅ Performance graphs (FPS vs. resolution)
- ✅ Convergence analysis (Quad LDS impact)
- ✅ Memory usage comparison (RMIP vs. tessellation)
- ✅ Quality metrics (Fast-MSX MSE improvement)
- ✅ Scalability analysis (if multiple GPUs available)

**Demo**:
- Recorded demo video (2-3 minutes) showcasing complete system
- Live interactive demo ready for presentation

**Metrics**:
- Comprehensive performance analysis for all four techniques
- Visual quality comparisons (before/after for each technique)
- Memory footprint breakdown
- Convergence rate improvements

### Final Submission (Dec 7): Polish & Documentation

**Code Quality**:
- ✅ Clean, well-commented code for all four techniques
- ✅ README with build instructions and quick start guide
- ✅ Technical documentation:
  - RMIP: Algorithm explanation, integration guide
  - Quad LDS: Generator construction, sampling implementation
  - Bounded VNDF: Spherical cap bounding, PDF computation
  - Fast-MSX: BRDF evaluation, integration with sampling
- ✅ API documentation (how to use material editor and features)

**Presentation Materials**:
- ✅ Slides (20-25 slides covering all four techniques)
- ✅ Demo video (2-3 minutes)
- ✅ Performance graphs for all techniques
- ✅ Visual comparisons (before/after, with/without for each technique)

**GitHub Repository**:
- ✅ Clean commit history showing progression through milestones
- ✅ Milestone tagging (Milestone 1, 2, 3, Final)
- ✅ Asset attribution (texture sources, reference code)
- ✅ License information (MIT or similar)

**Novel Contributions Documented**:
1. First combined 4-paper implementation (Quad LDS + RMIP + Bounded VNDF + Fast-MSX)
2. Vulkan-specific optimizations for all techniques
3. Complete material authoring workflow
4. Performance analysis on modern GPUs (RTX 4000 series)
5. Open-source material library with all four techniques demonstrated

---


## Implementation Roadmap (Nov 3 - Dec 7, 2025)

### Week 1: Nov 3-9 (Foundation & Setup)

#### All Team: Setup (Nov 3-4)
- [ ] **Day 1 (Nov 3)**: Fork vk_gltf_renderer, set up build environment
- [ ] **Day 2 (Nov 4)**: Study existing pipeline, divide code ownership

#### Person A: RMIP Foundation (Nov 5-9)
- [ ] Study RMIP paper, understand algorithm
- [ ] Design RMIP data structure (C++ class)
- [ ] Implement RMIP hierarchy builder (pre-processor)
  - Input: Displacement texture (PNG/EXR)
  - Output: RMIP min/max bounds per rectangular region
  - Test with simple height map
- [ ] Start custom intersection shader skeleton
- **Deliverable**: RMIP builder working, can load displacement and generate hierarchy

#### Person B: Quad LDS Foundation (Nov 5-9)
- [ ] Study Quad LDS paper and GitHub implementation
- [ ] Port generator matrix code from reference implementation
- [ ] Implement host-side pre-computation (C++)
  - Generate base-3 Sobol' tables
  - Optimize generator matrices for (1,4) sequences
- [ ] Start device-side sampling function (GLSL)
- **Deliverable**: Quad LDS generator working, can produce sample sequences

#### Person C: BRDF Infrastructure (Nov 5-9)
- [ ] Study Bounded VNDF and Fast-MSX papers
- [ ] Locate existing GGX sampler in vk_gltf_renderer
- [ ] Understand current BRDF evaluation pipeline
- [ ] Design integration strategy (where code goes)
- [ ] Create test scene with varying roughness materials
- **Deliverable**: Understanding of codebase, integration plan documented

### Week 2 (Nov 9-15): Milestone 1 - Core Implementations

This week focuses on completing the core implementation of each technique and preparing for Milestone 1 presentation.

#### Person A: RMIP Custom Intersection Shader (Nov 9-12)
- [ ] Complete RMIP traversal algorithm in custom intersection shader
- [ ] Implement ping-pong between texture-space and object-space bounds
- [ ] Implement texel marching and micro-triangle generation
- [ ] Test with simple displaced plane (single height map)
- [ ] Measure traversal steps and intersection cost per ray
- [ ] Prepare Milestone 1 demo: Displaced plane vs. flat plane

#### Person B: Quad LDS Device Integration (Nov 9-12)
- [ ] Complete device-side sampling function (GLSL)
- [ ] Integrate into path tracer's random number generation pipeline
- [ ] Replace existing Sobol'/PCG sampler calls
- [ ] Validate sample quality using discrepancy tests
- [ ] Create convergence comparison (Quad LDS vs Sobol' vs PCG)
- [ ] Prepare Milestone 1 demo: Convergence rate graphs

#### Person C: Bounded VNDF Implementation (Nov 9-12)
- [ ] Implement spherical cap bounding for GGX sampling
- [ ] Replace existing `SampleGGXVNDF()` function in `pbr_material_eval.h.slang`
- [ ] Update PDF computation for bounded sampling
- [ ] Test with varying roughness values (α = 0.1, 0.3, 0.5, 0.7, 0.9)
- [ ] Measure rejection rate reduction vs. standard VNDF
- [ ] Prepare Milestone 1 demo: Rejection rate comparison

#### All Team: Milestone 1 Preparation (Nov 12)
- [ ] **Milestone 1 Presentation** - Each person demos their technique individually
  - Person A: RMIP displacement rendering working
  - Person B: Quad LDS convergence comparison
  - Person C: Bounded VNDF sampling efficiency
- [ ] Show basic functionality and initial metrics
- [ ] Discuss integration plan for Week 3

**Deliverables**:
- ✅ RMIP: Working intersection shader, simple displaced geometry demo
- ✅ Quad LDS: Integrated sampling, discrepancy analysis, convergence graphs
- ✅ Bounded VNDF: Working sampler, rejection rate metrics, comparison with standard VNDF

### Week 3 (Nov 16-22): Integration & Fast-MSX

This week focuses on integrating all components and adding Fast-MSX BRDF evaluation.

#### Person A: RMIP Optimization & Materials (Nov 16-22)
- [ ] Optimize hierarchical traversal (early termination when bounds don't intersect)
- [ ] Implement adaptive texel marching (variable step size based on displacement gradient)
- [ ] Create displaced material variants:
  - [ ] Stone texture with displacement
  - [ ] Metal with hammered surface displacement
  - [ ] Wood with grain displacement
- [ ] Test with tiled displacement maps
- [ ] Integrate with Quad LDS sampling for ray jittering
- [ ] Profile RMIP performance: memory usage, traversal steps, FPS impact

#### Person B: Quad LDS Validation & System-Wide Integration (Nov 16-22)
- [ ] Validate (1,4)-sequence property in all dimension quadruplets
- [ ] Optimize device-side sampling performance (minimize register usage)
- [ ] Measure impact on convergence across entire renderer (all materials)
- [ ] Create comparison visualizations:
  - [ ] Equal-sample comparison (Quad LDS vs Sobol' at 256 spp)
  - [ ] Equal-time comparison (how many more samples in same time?)
  - [ ] Variance reduction graphs
- [ ] Ensure stable integration with RMIP and Bounded VNDF
- [ ] Document performance characteristics

#### Person C: Fast-MSX Implementation & Integration (Nov 16-22)
- [ ] Implement Fast-MSX BRDF evaluation (Algorithm 1 from paper):
  - [ ] Compute cavity orientation: `c = normalize(h + n)`
  - [ ] Compute G_I using relaxed V-cavity model
  - [ ] Compute D_I using modified GGX distribution
  - [ ] Compute Fresnel term: `F_I = F²`
  - [ ] Add multi-scatter term to single-scatter GGX
- [ ] Integrate with Bounded VNDF sampling (sample direction → evaluate with Fast-MSX)
- [ ] Create test scene with varying roughness spheres (α = 0.1 to 0.9)
- [ ] Measure MSE vs. ground truth reference (compare with paper Figure 3 results)
- [ ] Validate energy improvement for rough materials (α > 0.5)
- [ ] Test with both dielectric and metallic materials

#### All Team: Pipeline Integration (Nov 20-22)
- [ ] Integrate full pipeline: Quad LDS → RMIP → Bounded VNDF → Fast-MSX
- [ ] Test material combinations (displacement + varying roughness)
- [ ] Create initial material library (3-5 materials with all features enabled)
- [ ] Begin material parameter editor (ImGui sliders):
  - Displacement scale
  - Roughness value
  - Metallic toggle
  - Fast-MSX toggle (for comparison)
- [ ] Verify all techniques work together without interference

**Deliverables**:
- ✅ Complete pipeline working end-to-end
- ✅ Fast-MSX BRDF evaluation integrated
- ✅ Initial material library (3-5 materials)
- ✅ Performance and quality metrics for each component

### Week 4 (Nov 23-29): Milestone 2 & Production Features

This week focuses on Milestone 2 presentation and adding production-quality features.

#### Person A: Comparison Modes & RMIP Analysis (Nov 23-26)
- [ ] Implement RMIP toggle (compare with tessellation baseline or parallax mapping)
- [ ] Create side-by-side comparison view in UI
- [ ] Measure memory usage:
  - RMIP data structure size vs. tessellated mesh size
  - Texture memory for displacement maps
- [ ] Performance profiling:
  - Traversal cost breakdown (hierarchy levels, texel marching)
  - FPS with/without RMIP
  - Scalability with displacement resolution (2K vs 4K maps)
- [ ] Create multiple RMIP test scenes showcasing displacement detail

#### Person B: System-Wide Performance Analysis (Nov 23-26)
- [ ] Measure Quad LDS impact on convergence rate (samples to target MSE)
- [ ] Create comparison graphs:
  - Convergence curves (MSE vs. sample count)
  - Per-material convergence improvement
  - Correlation between technique and Quad LDS benefit
- [ ] Analyze performance overhead:
  - Sample generation cost (CPU/GPU time)
  - Memory footprint of generator matrices
- [ ] Optimize sample caching and pre-computation strategies
- [ ] Document when Quad LDS provides most benefit (high-roughness materials, etc.)

#### Person C: Material System & Fast-MSX Analysis (Nov 23-26)
- [ ] Implement Fast-MSX toggle (compare with standard GGX side-by-side)
- [ ] Complete material library expansion (7+ materials):
  - [ ] Rough stone (α=0.7, displacement)
  - [ ] Hammered copper (metallic, α=0.4, displacement)
  - [ ] Wood planks (anisotropic roughness, displacement)
  - [ ] Concrete (α=0.5, displacement)
  - [ ] Velvet/fabric (α=0.9, no displacement - showcase Fast-MSX)
  - [ ] Ceramic (α=0.3, displacement)
  - [ ] Brick wall (tiled displacement, α=0.5)
- [ ] Measure Fast-MSX quality improvement:
  - MSE vs. ground truth for each roughness level
  - Visual comparison images (GGX vs Fast-MSX)
  - Energy conservation analysis (furnace test if time permits)
- [ ] Create roughness-dependent performance analysis (overhead vs. α)

#### All Team: Milestone 2 Preparation (Nov 27-29)
- [ ] Create comprehensive benchmark suite:
  - [ ] FPS vs. resolution (1080p, 1440p, 2160p)
  - [ ] Performance breakdown per technique (pie chart showing cost)
  - [ ] Quality metrics (MSE, SSIM if time permits)
  - [ ] Memory usage comparison (table with all variants)
- [ ] Prepare multi-material showcase scene (all 7+ materials together)
- [ ] Implement comparison toggle modes for live demo
- [ ] **Milestone 2 Presentation** (Nov 24)
  - Demo integrated system
  - Show material library
  - Present performance benchmarks
  - Discuss optimization findings

**Deliverables**:
- ✅ Complete material library (7+ materials)
- ✅ Comparison modes working for all four techniques
- ✅ Comprehensive benchmark results with graphs
- ✅ Milestone 2 demo with integrated system

### Week 5 (Nov 30-Dec 6): Milestone 3 & Final Polish

This week focuses on Milestone 3, final optimizations, and comprehensive documentation.

#### Person A: Documentation & Technical Write-up (Nov 30-Dec 4)
- [ ] Write RMIP implementation documentation:
  - Algorithm explanation (inverse mapping, oblong bounding)
  - Data structure details (hierarchy construction)
  - Custom intersection shader code walkthrough
  - Integration guide for future users
- [ ] Code cleanup and detailed comments in:
  - `src/rmip_builder.cpp`
  - `shaders/rmip_intersection.h.slang`
  - `shaders/rmip_common.h.slang`
- [ ] README section: Build instructions and RMIP-specific setup
- [ ] Create RMIP-specific performance analysis document with graphs

#### Person B: Quad LDS Documentation & Analysis (Nov 30-Dec 4)
- [ ] Write Quad LDS implementation documentation:
  - Generator matrix construction (base-3 Sobol')
  - (1,4)-sequence properties explanation
  - Device-side sampling implementation
  - Integration with path tracer random number generation
- [ ] Create comprehensive convergence analysis document:
  - When to use Quad LDS vs. standard Sobol'
  - Performance characteristics
  - Integration guide
- [ ] Code cleanup and comments in:
  - Host-side generator code
  - Device-side sampling shader
- [ ] Document benefits across different material types

#### Person C: Material Editor & Final Features (Nov 30-Dec 4)
- [ ] Complete material editor with live preview:
  - [ ] Displacement scale slider (0.0 - 1.0)
  - [ ] Roughness adjustment (0.0 - 1.0)
  - [ ] Metallic toggle
  - [ ] Fast-MSX on/off toggle
  - [ ] Bounded VNDF on/off toggle
  - [ ] RMIP on/off toggle
  - [ ] Real-time parameter updates (immediate visual feedback)
- [ ] Create material presets and gallery UI
- [ ] Export functionality:
  - Save material parameters to JSON
  - Export to glTF material extension (if time permits)
- [ ] Record material quality demo video segment (90 seconds)

#### All Team: Final Presentation Preparation (Dec 5-6)
- [ ] **Milestone 3 Presentation** (Dec 1)
  - Show complete integrated system
  - Demo material editor
  - Present all benchmarks and analysis
  - Discuss novel contributions

- [ ] Create final presentation slides (20-25 slides):
  - [ ] Problem statement (realistic materials need geometric + optical complexity)
  - [ ] Four-technique overview (Quad LDS, RMIP, Bounded VNDF, Fast-MSX)
  - [ ] Implementation details for each technique
  - [ ] Integration pipeline diagram
  - [ ] Results: Material showcase with comparisons
  - [ ] Performance benchmarks (FPS, memory, convergence)
  - [ ] Novel contributions:
    - First combined 4-paper implementation
    - Vulkan-specific optimizations
    - Material authoring workflow
    - Performance analysis on RTX 4000-series
  - [ ] Lessons learned and future work

- [ ] Record final demo video (2-3 minutes):
  - [ ] Material showcase scene flythrough (30s)
  - [ ] Live parameter editing demo (45s)
  - [ ] Comparison modes showing impact of each technique (45s)
  - [ ] Performance graph overview (30s)

- [ ] Create performance graphs and visual comparisons:
  - [ ] FPS vs. resolution graph
  - [ ] Convergence rate comparison (Quad LDS benefit)
  - [ ] Memory usage comparison (RMIP vs tessellation)
  - [ ] Quality improvement graphs (Fast-MSX MSE reduction)
  - [ ] Side-by-side visual comparisons (before/after for each technique)

- [ ] Asset attribution and licensing:
  - [ ] Credit all texture sources (CC0, own creation, etc.)
  - [ ] Document third-party code usage (nvpro-core2, reference implementations)
  - [ ] Add LICENSE file (MIT or similar)

**Deliverables**:
- ✅ Complete documentation (README, technical docs for each technique)
- ✅ Final presentation materials ready (slides, demo video, graphs)
- ✅ Material editor fully functional with live preview
- ✅ All code cleaned, commented, and documented
- ✅ Milestone 3 presentation complete

### Week 6 (Dec 7-8): Final Submission

#### December 7 (11:59pm): Final Project Due
- [ ] Submit complete codebase to GitHub
- [ ] All documentation finalized and committed
- [ ] Benchmark results documented in README or separate docs folder
- [ ] Material library with proper attribution
- [ ] Clean commit history showing progression through milestones

#### December 8 (4:00pm): Final Presentation Due
- [ ] Upload final presentation slides (PDF)
- [ ] Upload demo video (MP4, 2-3 minutes)
- [ ] Submit performance graphs (PNG/PDF)
- [ ] Ensure all links work (GitHub repo, video, etc.)

#### December 8 (5:30pm): Live Presentation
- [ ] Present MatForge project to class
- [ ] Live demo of material editor and rendering system
- [ ] Q&A session
- [ ] Showcase novel contributions and results

---

## Novel Contributions (What Makes This A+ / Publication-Worthy)

### 1. First Combined 4-Paper Implementation

**Contribution**: Quad LDS + RMIP + Bounded VNDF + Fast-MSX have never been implemented together in a unified system.

**Why It Matters**:
- Demonstrates synergy across multiple rendering techniques
- Shows how sampling quality, geometric detail, efficient importance sampling, and realistic scattering work together
- Provides complete material rendering pipeline from foundation to final appearance
- Each technique amplifies the benefits of the others

**Measurable Impact**:
- Convergence analysis: How much faster does the full system converge vs. baseline?
- Visual quality: Side-by-side comparisons showing cumulative improvements
- Performance analysis: Cost vs. benefit for each technique in the pipeline
- Ablation study: Toggle each technique on/off to show individual contributions

### 2. Vulkan-Specific Optimizations for All Four Techniques

**Contribution**: First Vulkan implementation of RMIP and Quad LDS; optimized Vulkan integration of Bounded VNDF and Fast-MSX.

**Why It Matters**:
- RMIP paper used proprietary renderer
- Quad LDS reference is CPU-based, needs GPU adaptation
- Vulkan has unique features (descriptor indexing, custom intersection shaders, compute shader optimizations)
- Different optimization opportunities vs. other APIs (DXR, OptiX)

**Novel Aspects**:
- **RMIP**: Custom intersection shader optimization for Vulkan RT pipeline
- **Quad LDS**: GPU-efficient generator matrix storage and sampling
- **Bounded VNDF**: Integration with Vulkan's ray tracing pipeline
- **Fast-MSX**: Optimized BSDF evaluation in Slang shaders
- Unified descriptor set layout for efficient data access across all techniques

**Measurable Impact**:
- Compare with theoretical paper results for each technique
- Analyze Vulkan-specific bottlenecks (memory bandwidth, register pressure, etc.)
- Document optimization techniques for modern RT cores
- Performance breakdown showing cost of each technique

### 3. Complete Material Authoring Workflow

**Contribution**: Production-ready material editing tools integrating all four techniques.

**Why It Matters**:
- Papers provide algorithms, not artist workflows
- Real-world use requires iteration and parameter tweaking
- Material parameters interact (e.g., displacement scale affects scattering visibility, roughness affects sampling efficiency)
- Need to balance quality vs. performance across all four techniques

**Novel Aspects**:
- Real-time parameter editor with live preview:
  - Quad LDS sampling quality (sample count, dimension configuration)
  - RMIP displacement (scale, tiling, hierarchy depth)
  - Bounded VNDF efficiency (spherical cap bounds)
  - Fast-MSX scattering (roughness, metallic, multi-scatter contribution)
- Comparison modes: Toggle each technique individually or in combination
- Material presets showcasing best use cases for each technique
- Export to standard formats (JSON, glTF material extensions)

**Measurable Impact**:
- Material library size (7+ high-quality materials created)
- Workflow efficiency: Time to create material with full system vs. baseline
- User study potential: Artist feedback on workflow usability

### 4. Performance Analysis on Modern GPUs (RTX 4000 Series)

**Contribution**: Comprehensive performance study on latest GPU architecture.

**Why It Matters**:
- Papers from 2023-2024 used older GPUs (RTX 2000/3000 series)
- RTX 4000 has new features (Ada Lovelace architecture, SER, DMM, Shader Execution Reordering, Opacity Micromap)
- Real-time path tracing with advanced materials is now feasible
- Need to understand how each technique scales on modern hardware

**Novel Aspects**:
- **Per-Technique Analysis**:
  - Quad LDS: Sample generation cost, convergence rate improvements
  - RMIP: Traversal cost, memory bandwidth, custom intersection shader performance
  - Bounded VNDF: Rejection rate reduction, sampling efficiency
  - Fast-MSX: BRDF evaluation overhead, quality improvements
- **System-Wide Analysis**:
  - Scalability: Performance across GPU tiers (if multiple GPUs available)
  - Resolution scaling: 1080p → 1440p → 2160p
  - Comparison with baseline: Standard Sobol' + tessellation + standard VNDF + GGX
- **Production Recommendations**: When to use each technique, performance vs. quality trade-offs

**Measurable Impact**:
- FPS graphs at multiple resolutions showing impact of each technique
- Convergence rate improvements (samples to target MSE)
- Memory usage breakdown (RMIP data structures, Quad LDS tables, etc.)
- Identify bottlenecks and optimization opportunities
- Practical guidance for production use

### 5. Open-Source Material Library with Complete Pipeline

**Contribution**: High-quality material library demonstrating all four techniques working together.

**Why It Matters**:
- Community lacks test assets for advanced material rendering
- Displacement maps + PBR parameters + sampling configurations are tedious to create
- Enables researchers and developers to build on our work
- Demonstrates best practices for each technique

**Contents**:
- **7+ Production-Quality Materials**:
  - Rough stone (displacement + high roughness + multi-scatter)
  - Hammered copper (metallic + displacement + Bounded VNDF efficiency)
  - Wood planks (anisotropic roughness + displacement)
  - Concrete (medium roughness + displacement)
  - Velvet/fabric (high roughness, showcases Fast-MSX without displacement)
  - Ceramic (low-medium roughness + displacement)
  - Brick wall (tiled displacement + medium roughness)
- **Per-Material Documentation**:
  - Displacement maps (2K-4K resolution)
  - PBR parameters (roughness, metallic, base color)
  - Quad LDS configuration (dimension count, sample budget)
  - Bounded VNDF settings (spherical cap bounds)
  - Fast-MSX contribution (multi-scatter term weight)
  - Reference images (ground truth comparisons)
- **Integration Guide**:
  - How to author materials using all four techniques
  - Parameter tuning tips for each technique
  - Performance vs. quality trade-offs
  - glTF/USD integration examples

**Measurable Impact**:
- Community adoption (GitHub stars, forks, citations)
- Enables future research building on combined techniques
- Potential for publication (SIGGRAPH poster/demo, technical report)
- Educational value for students learning advanced rendering

---

## Risk Mitigation

### Risk 1: RMIP Implementation Complexity

**Risk**: Custom intersection shaders are complex, might not finish in time.

**Mitigation**:
- Start with basic version (no full hierarchy)
- Test with simple height maps first
- Have fallback: Basic parallax mapping as comparison baseline
- Milestone 1 focuses on RMIP - catch issues early

**Worst Case**: Partial RMIP (e.g., only 2-level hierarchy)
- Still shows concept
- Can measure partial speed-up
- Document limitations

### Risk 2: Fast-MSX Integration Issues

**Risk**: Fast-MSX might not integrate smoothly with existing BSDF.

**Mitigation**:
- Fast-MSX is only ~20 lines - low complexity risk
- Test standalone first (compare with paper results)
- Validate against reference images from paper
- Can implement as optional toggle (doesn't break existing renderer)

**Worst Case**: Fast-MSX only works for simple cases
- Still shows improvement for rough materials
- Document where it works well
- Suggest future improvements

### Risk 3: Performance Not Meeting Expectations

**Risk**: Combined system might be too slow for real-time.

**Mitigation**:
- Focus on quality first, performance second
- Can claim "interactive" (10-15 FPS) instead of "real-time" (30+ FPS)
- Adaptive quality settings (LOD for RMIP, roughness threshold for Fast-MSX)
- Comparison is still valuable even if slower

**Worst Case**: Only achieves 5-10 FPS at 1080p
- Still faster than ground truth (offline rendering)
- Document performance vs. quality trade-offs
- Position as "production preview" rather than "real-time game rendering"

### Risk 4: Material Library Creation Time

**Risk**: Creating high-quality materials takes longer than expected.

**Mitigation**:
- Start with 3 materials (stone, metal, wood)
- Use existing texture libraries (CC0 assets)
- Divide among team members (1-2 materials each)
- Focus on diversity (different roughness ranges)

**Worst Case**: Only 3-4 materials
- Still demonstrates technique
- Quality over quantity
- Community can contribute more later (open-source)

### Risk 5: Integration with vk_gltf_renderer Issues

**Risk**: Base repository might have bugs or incompatibilities.

**Mitigation**:
- Test build immediately (Week 1)
- Use stable release branch (not bleeding edge)
- nvpro-core2 is well-maintained (NVIDIA)
- Community support available (GitHub issues)

**Worst Case**: Need to use older version or different base
- vk_raytrace (SurfelPlus used this)
- Fallback: Minimal Vulkan RT app (more work, but doable)
- Can still deliver core techniques

---

## Success Criteria

### Minimum Viable Product (B+ Level)

- ✅ RMIP displacement ray tracing working (even if basic)
- ✅ Fast-MSX multiple scattering working (even if limited)
- ✅ 3 materials demonstrating both techniques
- ✅ Performance comparison (FPS, memory)
- ✅ Visual comparison (with/without)
- ✅ Code documented and buildable

### Strong Implementation (A Level)

- ✅ Full RMIP hierarchy with optimizations
- ✅ Fast-MSX for wide roughness range
- ✅ 5-7 materials with variety
- ✅ Material editor with live preview
- ✅ Comprehensive benchmarks
- ✅ Multiple test scenes
- ✅ Polished demo video

### Outstanding / Publication-Worthy (A+ / SIGGRAPH Level)

- ✅ Novel optimization techniques (Vulkan-specific)
- ✅ Material authoring workflow
- ✅ Extensive performance analysis
- ✅ Open-source material library
- ✅ Potential for technical paper/demo submission
- ✅ External validation (industry/academic feedback)

---

## Conclusion

**MatForge: Advanced Material Rendering System** is:

1. **Technically Sound**: Four published SIGGRAPH papers (2023-2024) from reputable researchers
2. **Feasible**: vk_gltf_renderer provides excellent foundation; each technique individually proven
3. **Complementary**: Sampling quality + geometric detail + efficient importance sampling + optical complexity = complete unified pipeline
4. **Novel**: First combined 4-paper implementation, Vulkan optimizations for all techniques, complete material workflow
5. **Measurable**: Clear performance and quality metrics for each technique and combined system
6. **Impactful**: Open-source contribution, comprehensive material library, production-ready tools
7. **Timeline-Appropriate**: 5 weeks with 3-person team, clear division of work
8. **Risk-Managed**: Multiple fallback options, incremental milestones, clean dependencies

**This project follows the SurfelPlus model**: Implement recent research + add novel extensions + achieve production quality + measurable impact.

**Status**: ✅ **Pitch approved November 3rd, 2025. Implementation phase in progress.**

---

## Team Division Summary

| Person | Primary Responsibility | Estimated LOC | Key Deliverables |
|--------|----------------------|---------------|------------------|
| **Person A** | RMIP (Displacement Ray Tracing) | ~800 lines | Custom intersection shader, RMIP builder, displaced materials |
| **Person B** | Quad-Optimized LDS (Sampling) | ~400 lines | Generator matrices, device sampling, convergence analysis |
| **Person C** | Bounded VNDF + Fast-MSX (Material) | ~350 lines | Spherical cap sampling, multi-scatter BRDF, material editor |

**Total**: ~1550 lines of new code (plus integration, testing, documentation)

---

## Appendix A: Pitch Feedback & Response (Nov 3, 2025)

### Feedback Received

**Positive:**
- ✅ Project approved with enthusiasm
- ✅ Thematic unity appreciated (all techniques focus on advanced materials)
- ✅ Clear technical depth demonstrated

**Concern:**
- ⚠️ "Might be too easy for three people" - original 2-paper scope seemed manageable but not challenging enough

### Our Response: Adding Third Paper (Quad LDS)

**Decision**: Added **Quad-Optimized Low-Discrepancy Sequences** (SIGGRAPH 2024) as third paper to address scope concern.

**Rationale:**
1. **Foundation Layer**: Quad LDS improves sampling quality for EVERYONE - benefits all other techniques
2. **Clear Ownership**: Person B owns Quad LDS exclusively, balancing workload
3. **Measurable Impact**: Convergence analysis shows clear contribution
4. **Thematic Fit**: Advanced sampling is fundamental to advanced material rendering

### Updated Structure: 4 Papers, 3 People

| Component | Person | Why It Fits |
|-----------|--------|-------------|
| Quad LDS | B | Foundation - better random numbers for entire system |
| RMIP | A | Geometry - displacement detail |
| Bounded VNDF | C | Sampling - efficient importance sampling |
| Fast-MSX | C | Materials - realistic scattering |

**Result**: Addresses "too easy" concern while maintaining thematic coherence and feasible scope.

---

## Appendix B: Success Criteria Reference

### Minimum Viable Product (B+ Level)

- ✅ All four techniques working individually
- ✅ Basic integration (Quad LDS → RMIP → Bounded VNDF → Fast-MSX)
- ✅ 3-5 materials demonstrating techniques
- ✅ Performance comparison (FPS, memory, convergence)
- ✅ Visual comparison (with/without each technique)
- ✅ Code documented and buildable

### Strong Implementation (A Level)

- ✅ Full integration with optimizations for all techniques
- ✅ 7+ materials with variety (roughness, displacement, metallic)
- ✅ Material editor with live preview
- ✅ Comprehensive benchmarks (FPS, convergence, memory, quality)
- ✅ Multiple test scenes (showcase, performance, quality, real-world)
- ✅ Polished demo video and presentation

### Outstanding / Publication-Worthy (A+ / SIGGRAPH Level)

- ✅ Novel optimization techniques (Vulkan-specific for all four papers)
- ✅ Complete material authoring workflow (production-ready tools)
- ✅ Extensive performance analysis (per-technique and system-wide)
- ✅ Open-source material library (community contribution)
- ✅ Ablation study (individual and combined impact of each technique)
- ✅ Potential for technical paper/poster submission
- ✅ External validation (industry/academic feedback)

---

**END OF PROJECT PLAN**
