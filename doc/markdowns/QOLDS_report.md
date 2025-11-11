# QOLDS Integration Report

**Author**: Person B (MatForge Team, CIS 5650 Fall 2025)
**Date**: November 4, 2025
**Purpose**: Investigation of current random number generation and QOLDS integration strategy

---

## Executive Summary

The base repository uses a **PCG (Permuted Congruential Generator)** random number generator for all Monte Carlo sampling in the path tracer. To integrate QOLDS (Quad-Optimized Low-Discrepancy Sequences), we need to:

1. Create GPU-side QOLDS sampling functions (Slang shaders)
2. Upload generator matrices and scrambling seeds to GPU buffers
3. Replace `rand(seed)` calls with `qolds_sample(index, dimension)` when enabled
4. Track sample indices and dimensions throughout the path tracer

**Status**: Host-side implementation (QOLDSBuilder) ✅ Complete | GPU-side implementation ⏳ Not Started

---

## 1. Current Random Number Generation System

### 1.1 Overview

The path tracer uses a **state-based pseudo-random number generator**:

- **Seed Generation**: `xxhash32(uint3(pixelX, pixelY, frameCount))`
  - Unique seed per pixel per frame
  - High-quality 32-bit hash function

- **Random Number Generation**: `rand(inout uint seed)`
  - Updates state using PCG algorithm
  - Returns float in [0, 1)
  - Sequential, correlated samples

### 1.2 Implementation Details

**File**: [build/_deps/nvpro_core2/nvshaders/random.h.slang](../../build/_deps/nvpro_core2/nvshaders/random.h.slang)

```slang
// Initialize seed from pixel coordinates and frame number
uint seed = xxhash32(uint3(uint2(samplePos.xy), pushConst.frameCount));

// Generate random numbers sequentially
float r1 = rand(seed);  // Updates seed internally
float r2 = rand(seed);  // Uses updated seed
float r3 = rand(seed);  // And so on...
```

**Key Characteristics**:
- ✅ Fast (minimal computational overhead)
- ✅ Good statistical properties
- ❌ **Correlated samples** (sequential generation)
- ❌ **No stratification** (samples can cluster)
- ❌ **Not a low-discrepancy sequence** (higher variance)

### 1.3 Usage Locations in Path Tracer

**File**: [shaders/gltf_pathtrace.slang](../../shaders/gltf_pathtrace.slang)

| Line | Purpose | Dimensions Used | Notes |
|------|---------|-----------------|-------|
| 811 | **Seed initialization** | - | `xxhash32(pixel, frame)` |
| 817 | **Subpixel jitter** (AA) | 2D | Gaussian sampling for antialiasing |
| 159, 172, 174 | **Light selection** | 1D per light | Multiple importance sampling |
| 188, 203 | **Environment sampling** | 2-3D | Sky or HDR importance sampling |
| 656 | **BSDF evaluation** | 3D | Material evaluation random numbers |
| 677 | **BSDF sampling** | 3D | Direction sampling for next bounce |
| 765-766 | **Depth of field** | 2D | Aperture sampling |
| 831 | **Multi-sample jitter** | 2D per sample | When `numSamples > 1` |
| 980, 1006 | **Opacity testing** | 1D | Alpha transparency |
| 730-731 | **Russian Roulette** | 1D | Path termination |

**Total Dimensions Per Path**: Approximately **10-20 dimensions** depending on:
- Path depth (each bounce needs ~4D for BSDF)
- Number of lights sampled
- Material complexity (transmission, opacity)
- Depth of field and antialiasing

---

## 2. QOLDS System Architecture

### 2.1 Host-Side (CPU) - Already Implemented ✅

**Files**:
- [src/qolds_builder.hpp](../../src/qolds_builder.hpp)
- [src/qolds_builder.cpp](../../src/qolds_builder.cpp)

**Functionality**:
- Load irreducible polynomials from [resources/initIrreducibleGF3.dat](../../resources/initIrreducibleGF3.dat)
- Generate base-3 Sobol' direction numbers
- Build generator matrices (D × m × m) for D dimensions
- Generate Owen scrambling seeds (one per dimension)
- Flatten matrices for GPU upload

**Example Usage**:
```cpp
QOLDSBuilder builder;
builder.loadInitData("resources/initIrreducibleGF3.dat");
builder.buildMatrices(8, 5);  // 8 dimensions, 3^5=243 max points
builder.generateScrambleSeeds();

// Get data for GPU upload
const std::vector<int32_t>& matrices = builder.getMatrixData();  // [D*m*m]
const std::vector<uint32_t>& seeds = builder.getScrambleSeeds(); // [D]
```

### 2.2 Device-Side (GPU) - To Be Implemented ⏳

**Target File**: `shaders/qolds_sampling.h.slang` (new file)

**Required Components**:

1. **Integer3 Struct** - Base-3 integer arithmetic
   ```slang
   struct Integer3 {
       int8_t digits[10];  // Up to 3^10 = 59,049

       __init(uint x);                    // Convert from uint
       float toDouble(uint m);            // Convert to [0,1)
       static int8_t mod(int x);          // x % 3
       static int8_t fma(int a, int b, int c);  // (a + b*c) % 3
   };
   ```

2. **Gray Code Generation** - For efficient traversal
   ```slang
   Integer3 graycode(Integer3 n);
   ```

3. **Point Generation** - Incremental Sobol' point construction
   ```slang
   Integer3 point3_digits(
       StructuredBuffer<int> matrix,
       uint m,
       Integer3 i3,
       inout Integer3 p3,
       inout Integer3 x3
   );
   ```

4. **Owen Scrambling** - Randomization
   ```slang
   Integer3 scramble_base3(
       Integer3 a3,
       uint seed,
       uint ndigits
   );
   ```

5. **Main API** - The function path tracer will call
   ```slang
   float qolds_sample(uint index, uint dimension);
   ```

### 2.3 GPU Buffer Requirements

**New Buffers Needed**:

1. **Generator Matrices Buffer**
   - Type: `StructuredBuffer<int32_t>`
   - Size: `D × m × m × sizeof(int32_t)` bytes
   - Example: 8 dims × 5 × 5 × 4 = 800 bytes
   - Layout: Row-major `matrices[d][row][col]`

2. **Scrambling Seeds Buffer**
   - Type: `StructuredBuffer<uint32_t>`
   - Size: `D × sizeof(uint32_t)` bytes
   - Example: 8 dims × 4 = 32 bytes

**Binding Points**: Add to [shaders/shaderio.h](../../shaders/shaderio.h)
```cpp
enum BindingPoints
{
  eTlas = 0,
  eOutImages,
  eTextures,
  // ... existing bindings ...
  eQoldsMatrices,    // NEW: QOLDS generator matrices
  eQoldsSeeds,       // NEW: Owen scrambling seeds
};
```

---

## 3. Integration Strategy

### 3.1 Dimension Assignment Strategy

QOLDS requires explicit dimension tracking. Here's the proposed dimension map for a single path:

| Dimension | Purpose | Notes |
|-----------|---------|-------|
| 0-1 | Camera ray jitter (AA) | Subpixel antialiasing |
| 2-3 | Depth of field | Aperture sampling (if enabled) |
| 4 | Light selection | Which light to sample |
| 5-6 | Light position sampling | 2D for area lights |
| 7-9 | BSDF evaluation | Material evaluation |
| 10-12 | BSDF sampling (bounce 0) | Next ray direction |
| 13 | Russian Roulette (bounce 0) | Path termination |
| 14-16 | BSDF sampling (bounce 1) | Second bounce |
| 17 | Russian Roulette (bounce 1) | ... |
| ... | ... | Up to maxDepth bounces |

**Total**: ~4-5 dimensions per bounce × maxDepth + 7 base = **27-32 dimensions** for typical scenes

**Configuration**: Use **D=48 dimensions** (maximum supported) with **m=5 digits** (243 points)

### 3.2 Sample Index Strategy

QOLDS uses a **global sample index** instead of per-pixel seeds:

**Current (PCG)**:
```slang
// Different seed per pixel
uint seed = xxhash32(uint3(pixelX, pixelY, frameCount));
```

**Proposed (QOLDS)**:
```slang
// Global sample index across all pixels
uint sampleIndex = frameCount * (imageWidth * imageHeight) + (pixelY * imageWidth + pixelX);
// OR simpler: just use frameCount if rendering one sample per pixel per frame
uint sampleIndex = frameCount;
```

**Rationale**:
- QOLDS sequences are designed for sequential sampling
- Each frame uses the next point in the sequence
- Better stratification across frames
- Supports progressive rendering

### 3.3 Code Modifications Required

#### 3.3.1 Renderer Setup (C++ Host Code)

**File**: [src/renderer.cpp](../../src/renderer.cpp)

**Changes**:
```cpp
#include "qolds_builder.hpp"

class GltfRenderer {
private:
    std::unique_ptr<QOLDSBuilder> m_qoldsBuilder;
    nvvk::Buffer m_qoldsMatricesBuffer;
    nvvk::Buffer m_qoldsSeedsBuffer;

public:
    void createVulkanScene() {
        // ... existing scene loading ...

        // Initialize QOLDS builder
        m_qoldsBuilder = std::make_unique<QOLDSBuilder>();
        if (!m_qoldsBuilder->loadInitData("resources/initIrreducibleGF3.dat")) {
            LOGE("Failed to load QOLDS initialization data\n");
            return;
        }

        // Build matrices: 48 dimensions, m=5 (243 points)
        m_qoldsBuilder->buildMatrices(48, 5);
        m_qoldsBuilder->generateScrambleSeeds();

        // Create GPU buffers
        createQoldsBuffers();
    }

    void createQoldsBuffers() {
        const auto& matrices = m_qoldsBuilder->getMatrixData();
        const auto& seeds = m_qoldsBuilder->getScrambleSeeds();

        // Create matrices buffer
        VkDeviceSize matrixSize = matrices.size() * sizeof(int32_t);
        m_qoldsMatricesBuffer = m_allocator.createBuffer(
            matrixSize,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
        );

        // Upload matrix data
        nvvk::StagingMemoryManager staging(&m_allocator);
        VkCommandBuffer cmd = m_app->createTempCmdBuffer();
        staging.cmdToBuffer(cmd, m_qoldsMatricesBuffer.buffer, 0, matrixSize, matrices.data());
        m_app->submitAndWaitTempCmdBuffer(cmd);

        // Create seeds buffer (similar process)
        // ...
    }

    void destroyResources() {
        m_allocator.destroy(m_qoldsMatricesBuffer);
        m_allocator.destroy(m_qoldsSeedsBuffer);
        // ... existing cleanup ...
    }
};
```

**File**: [src/resources.hpp](../../src/resources.hpp)

**Add QOLDS buffers**:
```cpp
struct Resources {
    // ... existing buffers ...

    // QOLDS buffers
    nvvk::Buffer qoldsMatricesBuffer;  // Generator matrices
    nvvk::Buffer qoldsSeedsBuffer;     // Scrambling seeds
};
```

#### 3.3.2 Path Tracer Shader Modifications

**File**: [shaders/gltf_pathtrace.slang](../../shaders/gltf_pathtrace.slang)

**Step 1**: Add bindings for QOLDS buffers
```slang
// Add after line 50 (existing bindings)
[[vk::binding(BindingPoints::eQoldsMatrices, 1)]]  StructuredBuffer<int>  qoldsMatrices;
[[vk::binding(BindingPoints::eQoldsSeeds, 1)]]     StructuredBuffer<uint> qoldsSeeds;
```

**Step 2**: Include QOLDS sampling header
```slang
// Add after line 41
#include "qolds_sampling.h.slang"  // NEW
```

**Step 3**: Modify `processPixel()` function (line 793+)
```slang
void processPixel(IRaytracer raytracer, float2 samplePos, float2 imageSize)
{
    // ... existing code ...

    // CHOOSE SAMPLING METHOD
    uint seed = 0;  // Will be used for PCG or dimension tracking
    uint sampleIndex = pushConst.frameCount;  // Global sample index for QOLDS
    uint currentDim = 0;  // Track current dimension

    if (pushConst.useQOLDS == 1) {
        // QOLDS mode: use sample index and dimension tracking
        seed = 0;  // Not used in QOLDS mode
    } else {
        // PCG mode: initialize seed as before
        seed = xxhash32(uint3(uint2(samplePos.xy), pushConst.frameCount));
    }

    // Subpixel jitter
    float2 subpixelJitter = float2(0.5f, 0.5f);
    if (pushConst.frameCount > 0) {
        float r1, r2;
        if (pushConst.useQOLDS == 1) {
            r1 = qolds_sample(sampleIndex, currentDim++);
            r2 = qolds_sample(sampleIndex, currentDim++);
        } else {
            r1 = rand(seed);
            r2 = rand(seed);
        }
        subpixelJitter += ANTIALIASING_STANDARD_DEVIATION * sampleGaussian(float2(r1, r2));
    }

    // ... rest of function ...
}
```

**Step 4**: Create sampling wrapper function
```slang
// Add helper function to abstract sampling
float sample1D(inout uint seed, inout uint dimension, uint index, bool useQOLDS) {
    if (useQOLDS) {
        return qolds_sample(index, dimension++);
    } else {
        return rand(seed);
    }
}

float2 sample2D(inout uint seed, inout uint dimension, uint index, bool useQOLDS) {
    return float2(
        sample1D(seed, dimension, index, useQOLDS),
        sample1D(seed, dimension, index, useQOLDS)
    );
}

float3 sample3D(inout uint seed, inout uint dimension, uint index, bool useQOLDS) {
    return float3(
        sample1D(seed, dimension, index, useQOLDS),
        sample1D(seed, dimension, index, useQOLDS),
        sample1D(seed, dimension, index, useQOLDS)
    );
}
```

**Step 5**: Replace all `rand(seed)` calls with wrapper
```slang
// Example: BSDF sampling (line 677)
// OLD:
sampleData.xi = float3(rand(seed), rand(seed), rand(seed));

// NEW:
sampleData.xi = sample3D(seed, currentDim, sampleIndex, pushConst.useQOLDS == 1);
```

**Locations to modify**:
- Line 159, 172, 174: Light sampling → `sample1D()`
- Line 188, 203: Environment sampling → `sample2D()` or `sample3D()`
- Line 656: BSDF evaluation → `sample3D()`
- Line 677: BSDF sampling → `sample3D()`
- Line 765-766: Depth of field → `sample2D()`
- Line 817, 831: Subpixel jitter → `sample2D()`
- Line 730: Russian Roulette → `sample1D()`

#### 3.3.3 Pass Parameters Through Call Chain

**Challenge**: `currentDim` and `sampleIndex` need to flow through:
- `processPixel()` → `samplePixel()` → `pathTrace()` → `sampleLights()`, etc.

**Solution 1 (Recommended)**: Use a sampling state struct
```slang
struct SamplingState {
    uint seed;           // For PCG mode
    uint sampleIndex;    // For QOLDS mode
    uint dimension;      // Current dimension in QOLDS
    bool useQOLDS;       // Which mode to use
};

// Initialize in processPixel()
SamplingState samplingState;
samplingState.seed = xxhash32(...);
samplingState.sampleIndex = pushConst.frameCount;
samplingState.dimension = 0;
samplingState.useQOLDS = (pushConst.useQOLDS == 1);

// Pass to all sampling functions
SampleResult pathTrace(IRaytracer raytracer, RayDesc ray, inout SamplingState sampling);
void sampleLights(..., inout SamplingState sampling, out DirectLight directLight);
```

**Solution 2 (Alternative)**: Global dimension counter (less clean)
```slang
static uint g_currentDimension = 0;  // Reset at start of each pixel
```

---

## 4. Implementation Checklist

### Week 2 (Nov 11-15): GPU Sampling Implementation

- [ ] **Day 1-2**: Create `shaders/qolds_sampling.h.slang`
  - [ ] Implement `Integer3` struct
  - [ ] Implement `graycode()`
  - [ ] Implement `point3_digits()`
  - [ ] Implement `scramble_base3()`
  - [ ] Implement `qolds_sample()` main API

- [ ] **Day 3**: GPU buffer creation and upload
  - [ ] Modify `src/renderer.cpp` to create QOLDS buffers
  - [ ] Add buffer bindings to shader
  - [ ] Test buffer upload (readback validation)

- [ ] **Day 4-5**: Minimal integration test
  - [ ] Add bindings to `gltf_pathtrace.slang`
  - [ ] Create sampling wrapper functions
  - [ ] Test with single dimension (subpixel jitter only)
  - [ ] Verify output matches reference

### Week 3 (Nov 18-22): Full Path Tracer Integration

- [ ] **Day 1-2**: Dimension tracking infrastructure
  - [ ] Create `SamplingState` struct
  - [ ] Thread through all functions
  - [ ] Map all dimensions (see Section 3.1)

- [ ] **Day 3-4**: Replace all sampling calls
  - [ ] Subpixel jitter
  - [ ] Depth of field
  - [ ] Light sampling
  - [ ] BSDF evaluation
  - [ ] BSDF sampling
  - [ ] Russian Roulette

- [ ] **Day 5**: Testing and validation
  - [ ] Render test scenes with QOLDS enabled
  - [ ] Compare with PCG baseline (should look similar)
  - [ ] Verify no regressions
  - [ ] Test toggle between PCG and QOLDS

### Week 4 (Nov 25-29): Validation and Analysis

- [ ] **Convergence Testing**
  - [ ] Render at multiple sample counts (16, 64, 256, 1024 SPP)
  - [ ] Compare MSE: QOLDS vs PCG
  - [ ] Measure variance reduction (target: 15-30%)

- [ ] **Discrepancy Analysis**
  - [ ] Export sample points
  - [ ] Compute star discrepancy
  - [ ] Verify (1,4)-sequence property

- [ ] **Performance Profiling**
  - [ ] Measure GPU overhead
  - [ ] Compare frame times
  - [ ] Optimize if needed (target: <1% overhead)

---

## 5. Expected Results

### 5.1 Visual Quality

**At Low Sample Counts (16-64 SPP)**:
- QOLDS should show **less noise** than PCG
- Better stratification → fewer clustered samples
- Smoother gradients, fewer visible artifacts

**At High Sample Counts (1024+ SPP)**:
- Both should converge to ground truth
- QOLDS reaches target quality **faster** (fewer samples needed)

### 5.2 Quantitative Metrics

Based on SIGGRAPH 2024 paper results:

| Metric | PCG (Baseline) | QOLDS | Improvement |
|--------|----------------|-------|-------------|
| Variance Reduction | 0% | 15-30% | ✅ Better |
| Star Discrepancy | ~0.15 | ~0.08 | ✅ Better |
| 4D Projection Quality | Poor | Excellent | ✅ Better |
| Sampling Overhead | 0ms | <0.1ms | ✅ Negligible |
| Convergence Rate | 1/√N | ~1.2/√N | ✅ 20% faster |

### 5.3 Success Criteria

**Minimum (Week 3)**:
- [ ] QOLDS produces correct samples (matches reference)
- [ ] Toggle works (can switch between PCG and QOLDS)
- [ ] No visual regressions (looks as good as PCG)

**Target (Week 4)**:
- [ ] 15-30% variance reduction vs PCG
- [ ] Discrepancy < 0.1 for 243 points
- [ ] Frame time overhead < 1%

**Stretch (Week 5)**:
- [ ] 4D projection analysis showing (1,4) property
- [ ] Convergence plots demonstrating faster convergence
- [ ] Publication-quality comparison images

---

## 6. Risks and Mitigation

### Risk 1: Complex Dimension Tracking

**Problem**: Maintaining dimension count through recursive path tracing is complex

**Mitigation**:
- Use `SamplingState` struct to encapsulate all state
- Pass by reference through all functions
- Add assertions to check dimension bounds

**Fallback**: Use fixed dimension assignments per bounce

### Risk 2: Performance Overhead

**Problem**: Base-3 arithmetic and scrambling might be slow on GPU

**Mitigation**:
- Use lookup tables for mod-3 and FMA operations
- Optimize `Integer3` struct layout
- Cache previous point state for incremental generation

**Fallback**: Disable scrambling (still valid LDS, just not randomized)

### Risk 3: Sample Count Limitation

**Problem**: QOLDS with m=5 only supports 243 samples (3^5)

**Impact**: Progressive rendering beyond 243 frames needs special handling

**Mitigation**:
- Use m=6 (729 points) or m=7 (2187 points) for longer sequences
- Wrap around to sample 0 after exhausting sequence
- Combine with frame-based scrambling (different seed per cycle)

**Fallback**: Switch to PCG after 243 frames

### Risk 4: Integration Bugs

**Problem**: Many code locations to modify, easy to miss dimension tracking

**Mitigation**:
- Systematic replacement using wrapper functions
- Test incrementally (one feature at a time)
- Visual validation at each step

**Fallback**: Keep PCG mode as stable baseline

---

## 7. Testing Strategy

### Unit Tests

1. **Integer3 Arithmetic**
   - Test conversion: `Integer3(123)` → base-3 digits
   - Test `mod()`, `fma()` operations
   - Test `toDouble()` conversion

2. **Point Generation**
   - Generate first 10 points, compare with reference
   - Verify incremental updates match batch generation

3. **Scrambling**
   - Same seed → same permutation
   - Different seeds → different patterns

### Integration Tests

1. **Single Dimension Test**
   - Replace only subpixel jitter with QOLDS
   - Visual comparison: should look similar to PCG

2. **Full Path Test**
   - Enable QOLDS for all dimensions
   - Render simple scene (sphere on plane)
   - Compare with PCG: similar appearance

3. **Toggle Test**
   - Switch between PCG and QOLDS at runtime
   - No crashes, consistent rendering

### Validation Tests

1. **Discrepancy Test**
   - Export 243 QOLDS samples
   - Compute star discrepancy
   - Should be < 0.1 (better than PCG's ~0.15)

2. **4D Projection Test**
   - Check consecutive 4-tuples
   - Verify good stratification
   - Demonstrates (1,4)-sequence property

3. **Convergence Test**
   - Render at 16, 64, 256, 1024 SPP
   - Plot MSE vs samples (log-log)
   - QOLDS should have lower MSE at same sample count

---

## 8. References

### Paper
- Ostromoukhov et al., "Quad-Optimized Low-Discrepancy Sequences", ACM SIGGRAPH 2024
- Location: [doc/papers/quad-optimized-sequence.pdf](../papers/quad-optimized-sequence.pdf)

### Reference Implementation
- GitHub: https://github.com/liris-origami/Quad-Optimized-LDS
- Local: [others/QOLDS](../../others/QOLDS)

### Project Documentation
- Implementation Plan: [QOLDS_impl_plan.md](QOLDS_impl_plan.md)
- Project Overview: [CLAUDE.md](../../CLAUDE.md)

### Code Locations
- **Path Tracer Shader**: [shaders/gltf_pathtrace.slang](../../shaders/gltf_pathtrace.slang)
- **Current RNG**: [build/_deps/nvpro_core2/nvshaders/random.h.slang](../../build/_deps/nvpro_core2/nvshaders/random.h.slang)
- **QOLDS Builder**: [src/qolds_builder.cpp](../../src/qolds_builder.cpp)
- **Push Constants**: [shaders/shaderio.h](../../shaders/shaderio.h)

---

## Appendix A: Sample Dimension Map (Detailed)

For a path with `maxDepth=5`, here's the complete dimension assignment:

```
Dimension  | Purpose                    | Notes
-----------+----------------------------+----------------------------------
0-1        | Subpixel jitter           | Antialiasing (always used)
2-3        | Depth of field            | Aperture (if aperture > 0)
4          | Light selection           | Which light to sample
5-6        | Light position            | Area light sampling
7-9        | BSDF eval (bounce 0)      | Material evaluation
10-12      | BSDF sample (bounce 0)    | Next direction
13         | Russian Roulette (b0)     | Path termination
14-16      | BSDF eval (bounce 1)      | Second bounce
17-19      | BSDF sample (bounce 1)    | ...
20         | Russian Roulette (b1)     | ...
21-23      | BSDF eval (bounce 2)      | Third bounce
24-26      | BSDF sample (bounce 2)    | ...
27         | Russian Roulette (b2)     | ...
28-30      | BSDF eval (bounce 3)      | Fourth bounce
31-33      | BSDF sample (bounce 3)    | ...
34         | Russian Roulette (b3)     | ...
35-37      | BSDF eval (bounce 4)      | Fifth bounce
38-40      | BSDF sample (bounce 4)    | ...
41         | Russian Roulette (b4)     | ...
42-47      | Reserved                  | Future use / extra samples
```

**Total Used**: ~42 dimensions for 5 bounces
**Configuration**: Use D=48 (all available dimensions)

---

## Appendix B: Quick Reference Commands

### Build and Test
```bash
# Rebuild project
cd build
cmake --build . --config Release

# Run renderer
..\_bin\Release\MatForge.exe

# Hot-reload shaders (in running app)
Press F5
```

### QOLDS Builder Test
```cpp
// In renderer.cpp
QOLDSBuilder builder;
builder.loadInitData("resources/initIrreducibleGF3.dat");
builder.buildMatrices(8, 5);  // 8D, 243 points
builder.generateScrambleSeeds(12345);  // Fixed seed for testing

std::cout << "Dimensions: " << builder.getDimensions() << std::endl;
std::cout << "Max points: " << builder.getMaxPoints() << std::endl;
```

### Toggle QOLDS in UI
1. Launch MatForge
2. Open "Settings" panel
3. Expand "Path Tracer" section
4. Check "Use QOLDS" checkbox
5. Observe rendering (should look similar to default)

---

**Status**: 📋 Report Complete | ⏭️ Next: Week 2 GPU Implementation
**Last Updated**: November 4, 2025
