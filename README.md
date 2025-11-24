# MatForge - Advanced Material Rendering System

<div align="center">

![MatForge Banner](img/thumb.png)

**A Production-Quality GPU Path Tracer Implementing Four Complementary SIGGRAPH Papers**

[![University of Pennsylvania](https://img.shields.io/badge/University-Penn-blue)](https://www.cis.upenn.edu/~cis5650/)
[![Course](https://img.shields.io/badge/Course-CIS%205650-red)](https://cis5650-fall-2024.github.io/)
[![Platform](https://img.shields.io/badge/Platform-Vulkan%201.3-green)](https://www.vulkan.org/)
[![Language](https://img.shields.io/badge/Shader-Slang-orange)](https://shader-slang.com/)

[Features](#features) • [Quick Start](#quick-start) • [Papers](#papers-implemented) • [Team](#team) • [Documentation](#documentation)

</div>

---

## Overview

**MatForge** is an advanced material rendering system developed for CIS 5650 GPU Programming at the University of Pennsylvania. The project implements **four complementary SIGGRAPH papers (2023-2024)** in a unified Vulkan-based path tracing pipeline, demonstrating state-of-the-art techniques for Monte Carlo sampling, displacement mapping, and physically-based material rendering.

### Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────┐
│             MatForge Rendering Pipeline                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. QUAD-OPTIMIZED LDS - Sampling Foundation                │
│     └─ Generate low-discrepancy random numbers              │
│        ↓                                                    │
│  2. RMIP - Geometry Detail                                  │
│     └─ Ray-trace displacement maps directly (WIP)           │
│        ↓                                                    │
│  3. BOUNDED VNDF - Direction Sampling                       │
│     └─ Efficient importance sampling                        │
│        ↓                                                    │
│  4. FAST-MSX - BRDF Evaluation                              │
│     └─ Multiple scattering approximation                    │
│        ↓                                                    │
│  5. MONTE CARLO INTEGRATION                                 │
│     └─ Combine: f(ωᵢ, ωₒ) × L(ωₒ) × cos(θ) / PDF            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Features

### ✅ Implemented (Milestone 2)

#### 🎲 Quad-Optimized Low-Discrepancy Sequences (QOLDS)

- **Paper**: "Quad-Optimized Low-Discrepancy Sequences" (SIGGRAPH 2024)
- **Implementation**: Complete host + device integration + convergence analysis
- Base-3 Sobol' sequence generator with irreducible polynomials
- Owen scrambling for randomization
- 47 dimensions × 243 max points (3^5)
- Real-time toggle between QOLDS and PCG sampling
- **Measured Results** (vs PCG random sampling):
  - **+2.57 dB PSNR improvement** at 512 samples per pixel
  - **44.7% MSE reduction** at 512 samples per pixel
  - **15-33% sample savings** for equivalent visual quality
  - **<1% performance overhead** (essentially free improvement)

#### ⚡ Fast-MSX (Fast Multiple Scattering Approximation)

- **Paper**: "Fast Multiple Scattering Approximation" (SIGGRAPH 2023)
- **Implementation**: BRDF evaluation with multi-scatter term
- Relaxed V-cavity model for GGX materials
- Modified geometry term (G_I) and distribution (D_I)
- Fresnel squared (F²) for multi-bounce energy
- Real-time toggle for comparison
- **Expected Benefits**: 100× better energy conservation at high roughness

#### 🎯 Bounded VNDF Sampling

- **Paper**: "Bounded VNDF Sampling for Smith-GGX Reflections" (SIGGRAPH Asia 2023)
- **Implementation**: Complete integration with GGX importance sampling
- Tighter spherical cap bounds for importance sampling
- Modified bound factor: `k = (1 - a²)s² / (s² + a²z²)`
- Reduces rejected samples for rough surfaces
- **Expected Benefits**: 15-40% variance reduction for α = 0.6-1.0

### 🚧 In Progress (Milestone 3 - Dec 1)

#### 🏔️ RMIP (Rectangular MinMax Image Pyramid)

- **Paper**: "Displacement ray-tracing via inversion and oblong bounding" (SIGGRAPH Asia 2023)
- **Status**: GPU compute pipeline operational, intersection shader loading functional
- Hierarchical min-max pyramid for displacement maps
- Custom intersection shader with KHR_materials_displacement support
- Test scene (`displaced_plane.gltf`) loading successfully
- ~5ms build time for 4K textures
- **Expected Benefits**: 11× faster than tessellation, 3× less memory

### 🛠️ Base Framework

Built on [NVIDIA nvpro-samples/vk_gltf_renderer](https://github.com/nvpro-samples/vk_gltf_renderer):

- **Graphics API**: Vulkan 1.3 with ray tracing extensions
- **Shader Language**: Slang with hot-reload support (F5)
- **Framework**: nvpro-core2 (NVIDIA Professional Graphics)
- **Path Tracer**: Adaptive sampling, MIS, optional DLSS-RR denoiser
- **Rasterizer**: PBR-based with HDR environment mapping
- **glTF 2.0**: Full scene loading support (.gltf/.glb)

---

## Quick Start

### Prerequisites

- **Vulkan SDK** 1.3 or later ([Download](https://vulkan.lunarg.com/sdk/home))
- **CMake** 3.20 or later
- **C++20 Compiler**:
  - Windows: Visual Studio 2022
  - Linux: GCC 11+ or Clang 14+
- **NVIDIA GPU**: RTX 20-series or newer (for ray tracing)
- **Git** with LFS support

### Build Instructions

```bash
# Clone the repository
git clone --recursive https://github.com/MatForge/MatForge.git
cd MatForge

# Configure with CMake
cmake -B build -S . -DUSE_DLSS=ON

# Build (Windows)
cmake --build build --config Release

# Build (Linux)
cmake --build build -- -j$(nproc)

# Run
./_bin/Release/MatForge
```

### First Run

1. The application will load the default shader ball scene
2. Press **F5** to reload shaders (hot-reload)
3. Use the GUI to toggle between rendering techniques:
   - **Use QOLDS**: Switch between QOLDS and PCG sampling
   - **Use FastMSX**: Toggle Fast-MSX multi-scatter evaluation
4. Load custom models: File → Open Scene (supports .gltf/.glb)
5. Load HDR environments: File → Open HDR

### Console Output

```
Creating Vulkan Context                -> 112.3 ms
Scene Loading                          -> 1.2 ms
[QOLDS] Loaded initialization data for 47 dimensions
[QOLDS] Built 47 matrices of size 5x5 (max 243 points)
[QOLDS] Generated 47 scrambling seeds
QOLDS buffers created: 47 dimensions, 243 max points
Path tracer initialized with PCG (default) sampling
```

**Toggle Messages**:

```
Switched to QOLDS sampling (Quad-Optimized Low-Discrepancy Sequences)
Switched to FastMSX (Fast Multiple Scattering)
Switched to Bounded VNDF sampling
```

**Convergence Test Output** (Milestone 2):

```
[Test] QOLDS vs PCG Convergence Analysis
[Test] Sample counts: 1, 2, 4, 8, 16, 32, 64, 128, 256, 512
[Test] At 512 SPP:
  - QOLDS: PSNR = 46.38 dB, MSE = 2.30e-05
  - PCG:   PSNR = 43.81 dB, MSE = 4.16e-05
  - Improvement: +2.57 dB, -44.7% MSE
[Test] Results saved to test/qolds_test_*.csv
```

---

## Papers Implemented

### 1. Quad-Optimized Low-Discrepancy Sequences

**Authors**: Victor Ostromoukhov et al.
**Published**: ACM SIGGRAPH 2024
**Location**: [doc/papers/quad-optimized-sequence.pdf](doc/papers/quad-optimized-sequence.pdf)
**Reference**: [others/QOLDS](others/QOLDS)

**What It Does**: Generates low-discrepancy sequences optimized for 2×2 pixel blocks (GPU quads), providing better space-filling properties than standard Sobol' sequences for Monte Carlo rendering.

**Key Innovation**: Base-3 Sobol' with (1,4)-sequence property + Owen scrambling

**Implementation**:

- Host-side: Generator matrix construction (`src/qolds_builder.cpp/hpp`)
- Device-side: GPU sampling function (`shaders/qolds_sampling.h.slang`)
- Integration: Path tracer with dimension tracking
- Convergence analysis: Automated testing framework with CSV/plot output
- **Status**: ✅ Complete + Validated (400 LOC)
- **Measured**: +2.57 dB PSNR, 44.7% MSE reduction vs PCG at 512 SPP

---

### 2. RMIP: Displacement Ray-Tracing via Inversion and Oblong Bounding

**Authors**: Théo Thonat, Iliyan Georgiev, François Beaune, Tamy Boubekeur (Adobe)
**Published**: ACM SIGGRAPH Asia 2023
**DOI**: [10.1145/3610548.3618182](https://doi.org/10.1145/3610548.3618182)
**Location**: [doc/papers/rmip.html](doc/papers/rmip.html)

**What It Does**: Enables tessellation-free displacement mapping for GPU ray tracing by ray-tracing displacement maps directly using hierarchical bounding.

**Key Innovation**: Combines inverse displacement mapping with oblong (rectangular) bounding in texture space.

**Implementation**:

- RMIP data structure builder (`src/rmip_builder.cpp/hpp`)
- GPU compute shaders (`shaders/rmip_*.compute.slang`)
- Custom intersection shader (`shaders/rmip_intersection.slang`)
- Descriptor set management for RMIP/displacement textures
- KHR_materials_displacement extension support
- **Status**: 🚧 In Progress - Loading functional, traversal WIP (~800 LOC)

---

### 3. Bounded VNDF Sampling for Smith-GGX Reflections

**Authors**: Kenta Eto & Yusuke Tokuyoshi (AMD)
**Published**: ACM SIGGRAPH Asia 2023
**DOI**: [10.1145/3610543.3626163](https://doi.org/10.1145/3610543.3626163)
**Location**: [doc/papers/bounded_VNDF.pdf](doc/papers/bounded_VNDF.pdf)

**What It Does**: Improves importance sampling for rough GGX materials by computing tighter spherical cap bounds, reducing rejected samples.

**Key Innovation**: Tighter bound `k = (1 - a²)s² / (s² + a²z²)` instead of conservative `-i_std.z`

**Implementation**:

- Integrated into `pbr_ggx_microfacet.h.slang`
- Modified GGX VNDF sampling with bounded spherical cap
- **Status**: ✅ Complete (200 LOC)

---

### 4. Fast Multiple Scattering Approximation

**Authors**: Unknown (SIGGRAPH 2023)
**Published**: ACM SIGGRAPH 2023
**Location**: [doc/papers/msx.pdf](doc/papers/msx.pdf)

**What It Does**: Adds a multi-scatter term to single-scatter GGX BRDF, improving energy conservation at high roughness with minimal overhead.

**Key Innovation**: Relaxed V-cavity model with modified distribution `D_I` and geometry term `G_I`

**Implementation**:

- BRDF evaluation (`shaders/fast_msx.h.slang`)
- Integration into path tracer with toggle
- **Status**: ✅ Complete (350 LOC)

---

## Project Structure

```
MatForge/
├── src/                          # C++ source code
│   ├── qolds_builder.cpp/hpp     # QOLDS matrix generation
│   ├── rmip_builder.cpp/hpp      # RMIP data structure builder
│   ├── renderer.cpp/hpp          # Main renderer
│   └── renderer_pathtracer.cpp   # Path tracer implementation
│
├── shaders/                      # Slang shaders
│   ├── qolds_sampling.h.slang    # QOLDS GPU sampling
│   ├── fast_msx.h.slang          # Fast-MSX BRDF evaluation
│   ├── rmip_*.compute.slang      # RMIP compute shaders (WIP)
│   └── gltf_pathtrace.slang      # Main path tracing shader
│
├── resources/                    # Assets
│   ├── models/                   # glTF models
│   ├── envmaps/                  # HDR environment maps
│   └── initIrreducibleGF3.dat    # QOLDS initialization data
│
├── doc/                          # Documentation
│   ├── markdowns/                # Technical documentation
│   │   ├── QOLDS_impl_plan.md
│   │   ├── RMIP_impl_plan.md
│   │   └── MSX_VNDF_impl_plan.md
│   ├── papers/                   # Research papers
│   └── presentations/            # Milestone presentations
│
└── CLAUDE.md                     # Developer guide
```

---

## Team

**Course**: CIS 5650 GPU Programming (Fall 2025)
**Institution**: University of Pennsylvania
**Timeline**: November 3 - December 7, 2025 (5 weeks)

| Team Member       | Responsibility          | Implementation                                        |
| ----------------- | ----------------------- | ----------------------------------------------------- |
| **Yiding**  | Quad-Optimized LDS      | Sampling + Convergence Analysis (✅ Complete)         |
| **Cecilia** | RMIP                    | Displacement ray tracing (🚧 Loading Complete, Traversal WIP) |
| **Xiaonan** | Fast-MSX + Bounded VNDF | Material system (✅ Both Complete)                    |

---

## Documentation

### Implementation Plans

- [QOLDS Implementation Plan](doc/markdowns/QOLDS_impl_plan.md)
- [RMIP Implementation Plan](doc/markdowns/RMIP_impl_plan.md)
- [Fast-MSX + Bounded VNDF Plan](doc/markdowns/MSX_VNDF_impl_plan.md)
- [Project Plan](doc/markdowns/PROJECT_PLAN.md)

### Milestone Reports

- [Milestone 1 Report](doc/presentations/Milestone1.md) (Nov 12, 2025)
- [Milestone 2 Report](https://docs.google.com/presentation/d/1KfiufcOu-iZWNO3kYZDekGecSDXhlwpd4ZzbTKqC-8c/edit?slide=id.g3a90943984b_1_633#slide=id.g3a90943984b_1_633) (Nov 24, 2025)

---

## Usage

### GUI Controls

**Rendering Techniques** (Path Tracer panel):

- ☑️ **Use QOLDS**: Enable Quad-Optimized Low-Discrepancy Sequences
- ☑️ **Use FastMSX**: Enable Fast Multiple Scattering (default: ON)
- ☑️ **Use Bounded VNDF**: Enable bounded importance sampling for GGX
- ☐ **Use RMIP**: Enable displacement ray tracing (coming in Milestone 3)

**Quality Settings**:

- **Samples**: Samples per pixel (1-64)
- **Max Depth**: Maximum ray bounce depth (1-10)
- **Firefly Clamp**: Threshold for firefly reduction

**Debug Visualizations**:

- Normal mapping
- Roughness/Metallic
- Base color
- Depth

### Keyboard Shortcuts

| Key             | Action                      |
| --------------- | --------------------------- |
| **F5**    | Reload shaders (hot-reload) |
| **F1**    | Toggle UI visibility        |
| **Space** | Pause/resume rendering      |
| **R**     | Reset camera                |

### Loading Custom Content

**Models**:

```bash
./MatForge --scenefile path/to/model.gltf
```

**HDR Environments**:

```bash
./MatForge --hdrfile path/to/environment.hdr
```

**Command Line Options**:

```bash
./MatForge --help
  --scenefile <path>     Load glTF scene
  --hdrfile <path>       Load HDR environment
  --size <width> <height> Window size
  --vsync                Enable V-Sync
  --headless             Run without window (benchmarking)
  --frames <count>       Number of frames (headless mode)
```

---

## Performance

### QOLDS Convergence Benchmarks (RTX 4070)

| Samples | QOLDS PSNR | PCG PSNR | Improvement | MSE Reduction |
|---------|------------|----------|-------------|---------------|
| 64      | 37.70 dB   | 37.24 dB | +0.46 dB    | 10.1%         |
| 128     | 40.67 dB   | 39.80 dB | +0.87 dB    | 18.2%         |
| 256     | 43.58 dB   | 42.03 dB | +1.55 dB    | 30.0%         |
| 512     | 46.38 dB   | 43.81 dB | **+2.57 dB**| **44.7%**     |

### Rendering Time (512 SPP)

| Sampler | Time (ms) | Overhead |
|---------|-----------|----------|
| PCG     | 25,741    | baseline |
| QOLDS   | 25,558    | **<1%**  |

**Key Finding**: QOLDS provides significant quality improvements with negligible performance overhead.

### Sample Savings for Equal Quality

| Target Quality | PCG Samples | QOLDS Samples | Savings |
|----------------|-------------|---------------|---------|
| 35 dB (preview)| ~40         | ~32           | ~20%    |
| 40 dB (good)   | ~150        | ~128          | ~15%    |
| 42 dB (excellent)| ~300      | ~200          | ~33%    |

## Milestones

### ✅ Milestone 1 (Nov 12, 2025) - COMPLETE

**Goal**: Individual techniques working (foundations)

**Deliverables**:

- ✅ QOLDS: Host + device + integration (400 LOC)
- ✅ Fast-MSX: BRDF evaluation (350 LOC)
- ✅ RMIP: GPU compute pipeline (800 LOC)

**Status**: All objectives met, ahead of schedule

---

### ✅ Milestone 2 (Nov 24, 2025) - COMPLETE

**Goal**: Full pipeline integration + convergence analysis

**Deliverables**:

- ✅ **QOLDS Convergence Analysis**: +2.57 dB PSNR, 44.7% MSE reduction at 512 SPP
- ✅ **Bounded VNDF**: Complete implementation integrated with GGX sampling
- ✅ **RMIP Loading**: Intersection shader loading functional, descriptor management fixed
- ✅ **Performance Benchmarks**: QOLDS has <1% overhead (negligible)
- ✅ **Automated Testing Framework**: CSV export, plot visualization
- 🚧 **RMIP Traversal**: In progress (texel marching algorithm)

---

### 🚧 Milestone 3 (Dec 1, 2025) - IN PROGRESS

**Goal**: Production features + comprehensive analysis

**Planned Deliverables**:

- ⏭️ **RMIP Traversal Complete**: Full texel marching with displaced surface intersection
- ⏭️ **Material Library**: 7+ materials demonstrating all techniques
- ⏭️ **Material Parameter Editor**: ImGui-based live editing
- ⏭️ **Side-by-Side Comparisons**: Visual comparisons with/without each technique
- ⏭️ **Perceptual Metrics**: SSIM, FLIP analysis
- ⏭️ **Demo Video**: Showcase all features

---

## Building from Source

### Windows (Visual Studio 2022)

```bash
# Configure
cmake -B build -S . -DUSE_DLSS=ON -DUSE_DRACO=ON

# Build
cmake --build build --config Release

# Run
.\_bin\Release\MatForge.exe
```

### Linux (GCC/Clang)

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt-get install vulkan-sdk libglfw3-dev

# Configure
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release

# Build
cmake --build build -- -j$(nproc)

# Run
./_bin/Release/MatForge
```

### Build Options

| Option                | Default | Description                       |
| --------------------- | ------- | --------------------------------- |
| `USE_DLSS`          | ON      | Enable NVIDIA DLSS-RR denoiser    |
| `USE_DRACO`         | ON      | Enable Draco mesh compression     |
| `USE_DEFAULT_SCENE` | OFF     | Embed default scene in executable |

---

## Troubleshooting

### Common Issues

**"QOLDS initialization file not found"**

```
Error: Could not open initialization file: resources/initIrreducibleGF3.dat
```

**Solution**: Ensure `resources/` directory is in the same location as the executable, or run from the project root.

**"Vulkan validation errors"**

```
Validation Error: vkCreateGraphicsPipelines: (...)
```

**Solution**: Update graphics drivers to the latest version. NVIDIA RTX 20-series or newer required.

**"Slang compilation failed"**

```
error 30047: argument passed to parameter '0' must be l-value
```

**Solution**: Press F5 to reload shaders. This issue should not occur in the current build.

**"Low FPS / Stuttering"**

- Reduce samples per pixel (try 1-4 for real-time preview)
- Lower max ray depth
- Disable DLSS if enabled
- Check GPU utilization in Task Manager

---

## Known Limitations

- RMIP traversal algorithm not yet complete (Milestone 3)
- Limited to 47 dimensions for QOLDS (sufficient for path tracing)
- QOLDS sequence length limited to 243 points (3^5)
- Fast-MSX works best with roughness > 0.5
- Bounded VNDF most effective for α = 0.6-1.0

---

## Contributing

This is an academic project for CIS 5650. While we appreciate feedback, we are not accepting external contributions during the course period (Nov 3 - Dec 7, 2025).

For questions or feedback:

- Open an issue on GitHub
- Contact the team via course channels

---

## License

This project is built on [nvpro-samples/vk_gltf_renderer](https://github.com/nvpro-samples/vk_gltf_renderer), which is licensed under the Apache License 2.0.

**MatForge Extensions**:

```
Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```

See [LICENSE](LICENSE) for full license text.

---

## Acknowledgments

- **Professor**: Shehzan Mohammed (CIS 5650, University of Pennsylvania)
- **Base Framework**: [NVIDIA nvpro-samples](https://github.com/nvpro-samples)
- **Papers**:
  - Ostromoukhov et al. (SIGGRAPH 2024) - Quad-Optimized LDS
  - Thonat et al. (SIGGRAPH Asia 2023) - RMIP
  - Eto & Tokuyoshi (SIGGRAPH Asia 2023) - Bounded VNDF
  - Fast-MSX (SIGGRAPH 2023) - Multiple Scattering
- **Reference Implementation**: [QOLDS GitHub](https://github.com/liris-origami/Quad-Optimized-LDS)

---

## Gallery

### QOLDS Convergence Analysis

![Convergence Comparison](test/convergence_comparison_20251122_141202.png)
*QOLDS vs PCG: +2.57 dB PSNR improvement, 44.7% MSE reduction at 512 SPP*

### QOLDS Sampling

![QOLDS Screenshot](doc/presentations/QOLDS_screenshot.png)
*Low-discrepancy sampling with 47 dimensions*

### Fast-MSX Comparison

![Fast-MSX Showcase](doc/presentations/img/msxshowcase.png)
*Multiple scattering approximation (left: without, right: with Fast-MSX)*

### RMIP Structure

![RMIP Structure](doc/presentations/RMIP_structure.png)
*Hierarchical min-max pyramid for displacement maps*

---

## Citations

If you use this work in your research, please cite:

```bibtex
@misc{matforge2025,
  title={MatForge: Advanced Material Rendering System},
  author={Yiding, Cecilia, Xiaonan},
  year={2025},
  institution={University of Pennsylvania, CIS 5650},
  url={https://github.com/MatForge/MatForge}
}
```

**Papers Implemented**:

```bibtex
@inproceedings{ostromoukhov2024quad,
  title={Quad-Optimized Low-Discrepancy Sequences},
  author={Ostromoukhov, Victor and others},
  booktitle={ACM SIGGRAPH 2024},
  year={2024}
}

@inproceedings{thonat2023rmip,
  title={RMIP: Displacement ray-tracing via inversion and oblong bounding},
  author={Thonat, Théo and Georgiev, Iliyan and Beaune, François and Boubekeur, Tamy},
  booktitle={ACM SIGGRAPH Asia 2023},
  year={2023},
  doi={10.1145/3610548.3618182}
}

@inproceedings{eto2023bounded,
  title={Bounded VNDF Sampling for Smith-GGX Reflections},
  author={Eto, Kenta and Tokuyoshi, Yusuke},
  booktitle={ACM SIGGRAPH Asia 2023},
  year={2023},
  doi={10.1145/3610543.3626163}
}
```

---

<div align="center">

**MatForge** - Advanced Material Rendering System
CIS 5650 GPU Programming | University of Pennsylvania | Fall 2025

[Documentation](doc/markdowns/) • [Implementation Plans](doc/markdowns/) • [Milestone Reports](doc/presentations/)

</div>
