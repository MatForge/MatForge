# MatForge: Advanced Material Rendering System

**Team**: 3 Students
**Project**: RMIP + Fast-MSX Combined Implementation
**One-Liner**: A Vulkan-based production material system combining tessellation-free displacement ray tracing (RMIP) with physically-accurate multiple scattering (Fast-MSX) for next-generation realistic materials.

---

## SLIDE 1: The Problem & Our Approach

### The Problem
Realistic materials require **both** geometric and optical complexity, but current approaches force a compromise:

- **Displacement mapping** → Requires millions of tessellated triangles → **Memory explosion** (500MB+ per 4K map)
- **Standard BRDFs** (GGX) → Energy loss at high roughness → **Unrealistic dark appearance**
- **No existing solution** addresses both problems together in real-time

### Our Approach: RMIP + Fast-MSX
**Combining two complementary SIGGRAPH 2023 papers:**

1. **RMIP** (SIGGRAPH Asia 2023) - Displacement ray-tracing via inversion and oblong bounding
   - Tessellation-free displacement: **11× faster**, **3× less memory** than traditional approaches
   - Direct ray tracing of displacement maps using custom intersection shaders

2. **Fast-MSX** (SIGGRAPH 2023) - Fast Multiple Scattering Approximation
   - Physically-accurate multiple scattering: **100× better energy conservation**, **5% overhead**
   - Closed-form solution for realistic rough material appearance

**Combined Result**: Production-quality materials with **both macro detail (RMIP) and micro appearance (Fast-MSX)**

---

**[END OF SLIDE 1]**

---

## SLIDE 2: Why This Matters

### Technical Significance

**✓ Novel Contributions Beyond Paper Reproduction:**
1. **First Combined Implementation** - No existing work combines displacement ray tracing with multi-scatter BRDFs
2. **First Vulkan Implementation of RMIP** - Papers used proprietary renderers; we bring this to open Vulkan
3. **Production Workflow** - Real-time material authoring tools with live parameter editing
4. **Modern GPU Analysis** - Performance characterization on RTX 4000 series with ray tracing optimizations

**✓ Industry-Relevant Problem:**
- AAA game engines (Unreal, Unity) still rely on tessellation for displacement → memory bottleneck for high-resolution assets
- Film/VFX renderers use expensive Monte Carlo for multiple scattering → slow iteration times
- Material artists need **both** geometric detail and optical realism → currently requires two separate workflows

**✓ Clear GPU Programming Focus:**
- Custom Vulkan ray tracing intersection shaders (VK_KHR_ray_tracing_pipeline)
- Shader Execution Reordering (SER) optimization for RTX 40+ series
- GPU-accelerated RMIP hierarchy traversal
- Real-time BRDF evaluation with Fast-MSX integration

### Real-World Impact
- **Open-source material library** for community use (5-7 production-ready materials)
- **Measurable improvements**: Memory reduction, FPS gains, visual quality metrics
- **Potential publication**: Technical demo/paper submission quality

---

**[END OF SLIDE 2]**

---

## SLIDE 3: Technical Approach & Deliverables

### Architecture Overview

```
glTF Scene → RMIP Builder → BLAS (AABB) → Custom Intersection Shader → Displaced Hit
                                              ↓
                                          Path Tracer
                                              ↓
                                    Material Evaluation (BRDF)
                                              ↓
                                    Fast-MSX Multi-Scatter → Final Radiance
```

**Base Repository**: Fork of [nvpro-samples/vk_gltf_renderer](https://github.com/nvpro-samples/vk_gltf_renderer)
- Production-quality Vulkan 1.3 path tracer with ray tracing
- Slang shader language with hot-reload (F5)
- Complete PBR material system (13 glTF extensions)
- Built-in profiling and performance tools

### Key Implementation Components

**RMIP (Displacement Ray Tracing):**
- Pre-process: Build hierarchical min/max bounds from displacement maps (~800 LOC)
- Runtime: Custom intersection shader with "ping-pong" traversal algorithm
- Integration: Modify BLAS for AABB geometry, extend Shader Binding Table (SBT)

**Fast-MSX (Multiple Scattering BRDF):**
- Core algorithm: ~20 lines (Algorithm 1 from paper)
- Integration: Extend existing `pbr_material_eval.h.slang` with additive multi-scatter term
- UI: Toggle and parameter controls (~150 LOC total)

### Milestone Schedule

**Milestone 1 (Nov 12)**: Foundations
- RMIP data structure builder + basic intersection shader
- Fast-MSX BRDF implementation + path tracer integration
- Demo: Displaced plane vs. tessellation; sphere array with varying roughness

**Milestone 2 (Nov 24)**: Integration & Material Library
- Combined RMIP + Fast-MSX pipeline working
- 5-7 materials: rough stone, hammered metal, wood planks, concrete, brick wall
- Material parameter editor with live preview
- Performance optimization (adaptive traversal, early exits)

**Milestone 3 (Dec 1)**: Production Features
- Comparison modes (toggle RMIP/Fast-MSX independently)
- Multiple test scenes (showcase, performance, quality, real-world)
- Benchmark suite (FPS graphs, memory analysis, quality metrics)

**Final (Dec 7)**: Polish & Documentation
- Code documentation, README, build instructions
- Final presentation materials + demo video (2-3 minutes)
- Open-source release with material library

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
- 1080p Interactive: 30-60 FPS
- 1080p Balanced: 20-30 FPS
- 1440p/2160p: 10-20 FPS (quality mode)

### Third-Party Code & Attribution

**Base Framework** (nvpro-core2):
- nvpro-samples/vk_gltf_renderer - Vulkan glTF path tracer (Apache 2.0 License)
- nvpro-core2 framework - NVIDIA Professional Graphics utilities
- Will be clearly credited in README and code headers

**Dependencies** (auto-downloaded via CMake):
- Slang shader compiler
- RapidJSON for glTF parsing
- MikkTSpace for tangent calculation
- Optional: DRACO mesh compression, DLSS SDK

**All third-party code is for infrastructure only** - Core contributions (RMIP algorithm, Fast-MSX BRDF, combined pipeline) are our original implementation.

### References & Inspiration

**Papers:**
1. Thonat et al., "RMIP: Displacement ray-tracing via inversion and oblong bounding", SIGGRAPH Asia 2023
   DOI: https://doi.org/10.1145/3610548.3618182

2. "Fast-MSX: Fast Multiple Scattering Approximation", SIGGRAPH 2023

**Similar Successful Approach:**
- SurfelPlus (CIS 5650 Fall 2024) - Combined EA SEED surfels + novel reflection acceleration → SIGGRAPH 2025 acceptance
- Our approach: Fork production renderer + implement recent research + novel extensions

**Material Assets:**
- CC0 texture libraries (ambientCG, Poly Haven)
- glTF sample models from Khronos Group

### Risk Mitigation

**If RMIP is too complex**: Partial hierarchy (2-level) still demonstrates concept; fallback to parallax mapping for comparison

**If Fast-MSX integration issues**: Standalone implementation still valuable; only ~20 LOC core algorithm

**If combined performance is slow**: Position as "production preview" (10 FPS) rather than real-time; quality/performance trade-off analysis still valuable

**Progressive deliverables** ensure partial success even if full integration is challenging.

---

**[END OF SLIDE 4]**

---

## Team & Contact

**Team Size**: 3 students (optimal for this scope)
**Repository**: Will be public on GitHub after pitch approval
**Industry Connections**: Can reach out to NVIDIA (Eric Haines), Google/Chrome (Shrek Shao for WebGPU port), original paper authors

**Questions?**

---

*Ready to bring production-quality advanced materials to Vulkan ray tracing!*
