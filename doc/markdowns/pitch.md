# MatForge: Advanced Material Rendering System

**Team**: 3 Students
**Project**: 4-Paper Combined Implementation (Quad LDS + RMIP + Bounded VNDF + Fast-MSX)
**One-Liner**: A complete Vulkan-based material rendering pipeline integrating foundation-to-finish optimizations: advanced sampling (Quad LDS), tessellation-free displacement (RMIP), efficient importance sampling (Bounded VNDF), and physically-accurate multiple scattering (Fast-MSX).

---

## SLIDE 1: The Problem & Our Approach

### The Problem
Advanced material rendering requires a complete pipeline, but each stage has fundamental limitations:

- **Sampling Quality** → Standard Sobol' sequences have poor uniformity in consecutive 4D projections → slower convergence
- **Geometric Detail** → Displacement mapping requires millions of tessellated triangles → **Memory explosion** (500MB+ per 4K map)
- **Importance Sampling** → Standard VNDF sampling wastes 15-40% of samples on invalid directions → variance and wasted computation
- **Material Appearance** → Standard BRDFs (GGX) → Energy loss at high roughness → **Unrealistic dark appearance**
- **No existing solution** addresses all four stages together in real-time

### Our Approach: Complete 4-Stage Pipeline
**Combining FOUR complementary SIGGRAPH 2023-2024 papers:**

1. **Quad-Optimized LDS** (SIGGRAPH 2024) - Foundation: Better Random Numbers
   - Optimized base-3 Sobol' sequences with **(1,4)-sequence** property
   - Faster convergence for path tracing (better sample uniformity)

2. **RMIP** (SIGGRAPH Asia 2023) - Geometry: Tessellation-Free Displacement
   - **11× faster**, **3× less memory** than traditional approaches
   - Direct ray tracing using custom intersection shaders

3. **Bounded VNDF** (SIGGRAPH Asia 2023) - Sampling: Efficient Importance Sampling
   - **15-40% variance reduction** for rough materials
   - Spherical cap bounding eliminates invalid samples

4. **Fast-MSX** (SIGGRAPH 2023) - Materials: Multiple Scattering
   - **100× better energy conservation**, **5% overhead**
   - Closed-form solution for realistic rough material appearance

**Combined Result**: Foundation → Geometry → Sampling → Shading = **Complete production-quality material pipeline**

---

**[END OF SLIDE 1]**

---

## SLIDE 2: Why This Matters

### Technical Significance

**✓ Novel Contributions Beyond Paper Reproduction:**

1. **First 4-Paper Combined Implementation** - No existing work combines Quad LDS + RMIP + Bounded VNDF + Fast-MSX
   - Each technique amplifies the benefits of others (better sampling → better BRDF → better displacement detail)
   - Complete pipeline from foundation (sampling) to finish (appearance)

2. **First Vulkan Implementation** - All four papers used proprietary renderers or CPU-based reference code
   - Quad LDS: Reference is CPU-based, needs GPU adaptation with generator matrix optimization
   - RMIP: Custom intersection shaders optimized for Vulkan RT pipeline
   - Bounded VNDF: Integration with Vulkan's ray tracing and descriptor indexing
   - Fast-MSX: Slang shader implementation with hot-reload support

3. **Production-Ready Workflow** - Complete material authoring system
   - Real-time parameter editing with live preview for all four techniques
   - Ablation study tools (toggle each technique individually)
   - Material presets demonstrating best use cases

4. **Modern GPU Analysis** - Performance characterization on RTX 4000 series (Ada Lovelace)
   - Shader Execution Reordering (SER) benefits for RMIP traversal
   - Per-technique performance breakdown and optimization strategies
   - Convergence analysis showing Quad LDS impact across entire pipeline

**✓ Industry-Relevant Problem:**

- **AAA Games**: Memory bottleneck from tessellated displacement → RMIP solves this
- **Film/VFX**: Slow convergence from poor sampling → Quad LDS accelerates
- **Real-Time Rendering**: Inefficient BRDF sampling → Bounded VNDF reduces variance
- **Material Artists**: Unrealistic rough materials → Fast-MSX fixes energy loss

**✓ Clear GPU Programming Focus:**

- **Custom ray tracing**: Intersection shaders, BLAS/TLAS management, SBT configuration
- **Advanced sampling**: GPU-optimized generator matrices, low-discrepancy sequences
- **Shader optimization**: Register pressure, occupancy, cache coherence for all techniques
- **Performance analysis**: Nsight profiling, per-technique cost breakdown

### Real-World Impact

- **Open-source material library** (7+ production-ready materials demonstrating all techniques)
- **Measurable improvements**: Convergence rate, memory reduction, variance reduction, energy conservation
- **Educational value**: Complete reference implementation for four recent SIGGRAPH papers
- **Potential publication**: First combined system, novel Vulkan optimizations

---

**[END OF SLIDE 2]**

---

## SLIDE 3: Technical Approach & Deliverables

### Architecture Overview - Complete 4-Stage Pipeline

```
                          ┌─────────────────────────────────────┐
                          │      MatForge Pipeline              │
                          ├─────────────────────────────────────┤
                          │                                     │
glTF Scene ───────────→   │  1. QUAD LDS (Person B)            │
                          │     └─ Generate high-quality        │
                          │        random numbers               │
Displacement Maps ─────→  │        ↓                           │
                          │  2. RMIP (Person A)                │
                          │     └─ Displacement ray tracing    │
                          │        ↓                           │
                          │  3. BOUNDED VNDF (Person C)        │
                          │     └─ Efficient importance sample │
                          │        ↓                           │
                          │  4. FAST-MSX (Person C)            │
                          │     └─ Multiple scattering BRDF    │
                          │        ↓                           │
                          │  FINAL RADIANCE                    │
                          └─────────────────────────────────────┘
```

**Base Repository**: Fork of [nvpro-samples/vk_gltf_renderer](https://github.com/nvpro-samples/vk_gltf_renderer)
- Production-quality Vulkan 1.3 path tracer with ray tracing
- Slang shader language with hot-reload (F5)
- Complete PBR material system (13 glTF extensions)
- Built-in profiling and performance tools

### Team Division & Implementation Components

**Person A - RMIP (Displacement Ray Tracing):** ~800 LOC
- Pre-process: Build hierarchical min/max bounds from displacement maps
- Runtime: Custom intersection shader with "ping-pong" traversal algorithm
- Integration: Modify BLAS for AABB geometry, extend Shader Binding Table (SBT)

**Person B - Quad-Optimized LDS (Sampling Foundation):** ~400 LOC
- Host-side: Generator matrix construction (base-3 Sobol' optimization)
- Device-side: GPU-efficient sampling function
- Integration: Replace path tracer's random number generation
- Analysis: Discrepancy measurement and convergence comparison

**Person C - Bounded VNDF + Fast-MSX (Efficient Sampling + Materials):** ~350 LOC
- Bounded VNDF: Spherical cap bounding for GGX sampling (~200 LOC)
- Fast-MSX: Multi-scatter BRDF evaluation (~20 LOC core, ~150 LOC total)
- Integration: Extend `pbr_material_eval.h.slang` with both techniques
- Material editor: UI controls for all parameters

### Milestone Schedule

**Milestone 1 (Nov 12)**: Individual Technique Foundations

- **Person A**: RMIP data structure builder + custom intersection shader working
- **Person B**: Quad LDS generator matrices + device sampling integrated
- **Person C**: Bounded VNDF sampler + basic Fast-MSX implementation
- **Demo**: Three individual demos showing each technique's impact

**Milestone 2 (Nov 24)**: Integration & Material System

- **All 4 techniques working together**: Quad LDS → RMIP → Bounded VNDF → Fast-MSX
- **Material library**: 7+ materials (stone, hammered copper, wood, concrete, velvet, ceramic, brick)
- **Material editor**: Live parameter editing with real-time preview
- **Comparison modes**: Toggle each technique on/off for ablation study
- **Performance optimization**: Per-technique profiling and optimization

**Milestone 3 (Dec 1)**: Production Features & Analysis

- **Advanced features**: Complete material authoring workflow, presets, export functionality
- **Multiple test scenes**: Showcase, performance stress test, quality comparison, real-world architectural
- **Comprehensive benchmarks**: FPS vs. resolution, convergence analysis, memory comparison, quality metrics
- **Ablation study**: Measure individual and combined impact of each technique

**Final (Dec 7)**: Polish & Documentation

- **Complete documentation**: Per-technique implementation guides, API docs, README
- **Presentation materials**: Slides (20-25), demo video (2-3 min), performance graphs
- **Open-source release**: Material library, build instructions, asset attribution

---

**[END OF SLIDE 3]**

---

## SLIDE 4: Technical Details & Third-Party Code

### APIs & Platforms

**Graphics APIs:**

- Vulkan 1.3 (VK_KHR_ray_tracing_pipeline, VK_KHR_ray_tracing_maintenance1)
- Slang shader language (cross-compilation to SPIR-V)

**Development Platform:**

- C++20, CMake build system
- Windows/Linux (cross-platform via Vulkan)

**Target Hardware:**

- NVIDIA RTX 4070 (team member GPU)
- Minimum: RTX 2060+ (any RTX GPU with ray tracing)

**Performance Targets:**

- 1080p Interactive: 30-60 FPS (with all 4 techniques enabled)
- 1080p Balanced: 20-30 FPS
- 1440p/2160p: 10-20 FPS (quality mode)

### Third-Party Code & Attribution

**Base Framework** (nvpro-core2):

- nvpro-samples/vk_gltf_renderer - Vulkan glTF path tracer (Apache 2.0 License)
- nvpro-core2 framework - NVIDIA Professional Graphics utilities
- Will be clearly credited in README and code headers

**Reference Implementations** (for algorithm verification):

- Quad LDS: GitHub reference code (https://github.com/liris-origami/Quad-Optimized-LDS)
  - Used for generator matrix construction methodology
  - GPU adaptation and optimization is our original work
- Bounded VNDF: AMD GPUOpen paper with pseudocode
  - Algorithm implementation is our original work
- RMIP & Fast-MSX: No reference code available (algorithm from papers only)

**Dependencies** (auto-downloaded via CMake):

- Slang shader compiler
- RapidJSON for glTF parsing
- MikkTSpace for tangent calculation
- Optional: DRACO mesh compression, DLSS SDK

**All core algorithms are our original implementations** - Reference code used only for validation and generator matrix construction methodology. The complete 4-technique pipeline, Vulkan integration, and material workflow are entirely our contribution.

### References & Inspiration

**Papers (All SIGGRAPH 2023-2024):**

1. **Quad-Optimized LDS**: Ostromoukhov et al., "Quad-Optimized Low-Discrepancy Sequences", SIGGRAPH 2024
   - DOI: <https://dl.acm.org/doi/10.1145/3641519.3657431>
   - GitHub: <https://github.com/liris-origami/Quad-Optimized-LDS>

2. **RMIP**: Thonat et al., "Displacement ray-tracing via inversion and oblong bounding", SIGGRAPH Asia 2023
   - DOI: <https://doi.org/10.1145/3610548.3618182>

3. **Bounded VNDF**: Tokuyoshi & Eto (AMD), "Bounded VNDF Sampling for Smith-GGX", SIGGRAPH Asia 2023 / I3D 2024
   - DOI: <https://dl.acm.org/doi/10.1145/3651291>
   - PDF: <https://gpuopen.com/download/publications/Bounded_VNDF_Sampling_for_Smith-GGX_Reflections.pdf>

4. **Fast-MSX**: "Fast Multiple Scattering Approximation", SIGGRAPH 2023

**Similar Successful Approach:**

- SurfelPlus (CIS 5650 Fall 2024) - Combined EA SEED surfels + novel reflection acceleration → SIGGRAPH 2025 acceptance
- Our approach: Fork production renderer + implement recent research + novel extensions + unified system

**Material Assets:**

- CC0 texture libraries (ambientCG, Poly Haven)
- glTF sample models from Khronos Group

### Risk Mitigation & Fallback Plans

**Clean Dependency Structure** minimizes risk:

- **Quad LDS** (Person B): No dependencies → can work in parallel from day 1
- **RMIP** (Person A): Minimal dependency on Quad LDS → parallel development
- **Bounded VNDF** (Person C): Depends on Quad LDS → integration in Week 2-3
- **Fast-MSX** (Person C): Depends on Bounded VNDF → sequential implementation

**Per-Technique Fallbacks:**

- **If Quad LDS GPU optimization is difficult**: CPU-based generator still provides correct samples; show convergence improvement even if slower
- **If RMIP is too complex**: Partial hierarchy (2-level) demonstrates concept; fallback to parallax mapping for comparison
- **If Bounded VNDF has integration issues**: Standard VNDF still works; show variance reduction in isolated test
- **If Fast-MSX integration issues**: Standalone implementation still valuable; only ~20 LOC core algorithm

**If combined performance is slow**: Position as "interactive preview" (10-15 FPS) rather than real-time; quality/performance trade-off analysis still valuable

**Progressive deliverables** (3 milestones) ensure partial success even if full integration is challenging. Each technique works standalone.

---

**[END OF SLIDE 4]**

---

## Team & Contact

**Team Size**: 3 students (well-balanced for 4-paper scope)

**Work Division**:

- Person A: RMIP (Displacement) - ~800 LOC
- Person B: Quad LDS (Sampling) - ~400 LOC
- Person C: Bounded VNDF + Fast-MSX (Materials) - ~350 LOC
- **Total**: ~1550 LOC + integration, testing, documentation

**Repository**: Will be public on GitHub (post-pitch approval)

**Industry Connections**:

- NVIDIA (Eric Haines - ray tracing)
- AMD (Yusuke Tokuyoshi - Bounded VNDF author)
- Original paper authors for all four techniques
- Potential WebGPU port (Shrek Shao, Google Chrome team)

**Why 4 Papers Works**:

- **Clear ownership**: Each person has dedicated technique(s)
- **Minimal blocking**: Clean dependency chain allows parallel work
- **Thematic unity**: All four optimize different stages of material rendering
- **Measurable impact**: Each technique has quantifiable metrics (convergence, memory, variance, energy)

**Questions?**

---

*Ready to bring a complete production-quality material pipeline to Vulkan ray tracing!*
