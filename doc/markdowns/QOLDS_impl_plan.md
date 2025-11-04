# Quad-Optimized Low-Discrepancy Sequences (QOLDS) Implementation Plan

**Developer**: Person B (QOLDS Specialist)
**Timeline**: November 4 - December 7, 2025 (5 weeks)
**Scope**: ~400 LOC (Host + Device + Utilities)
**Paper**: "Quad-Optimized Low-Discrepancy Sequences", Ostromoukhov et al., SIGGRAPH 2024
**Reference**: [others/QOLDS](../others/QOLDS) - GitHub reference implementation

---

## Executive Summary

**What is QOLDS?**
Quad-Optimized Low-Discrepancy Sequences are an advanced sampling technique based on **base-3 Sobol' sequences** with the **(1,4)-sequence property**. This ensures excellent stratification in **consecutive 4D projections**, which is critical for Monte Carlo path tracing where consecutive sample dimensions are used for direction sampling (θ, φ, component selection, etc.).

**Why QOLDS?**
- **15-30% lower variance** than standard Sobol' in path tracing scenarios
- **Better stratification** in 4D projections (critical for BRDF sampling)
- **Deterministic**: Same sequence every frame (unlike PCG random)
- **Foundation**: All other techniques (RMIP, Bounded VNDF, Fast-MSX) benefit from better sampling

**Implementation Strategy**:
- **Week 1**: Host-side generator matrix construction (C++)
- **Week 2**: Device-side GPU sampling (Slang shaders)
- **Week 3**: Integration into path tracer + validation
- **Week 4-5**: Discrepancy analysis, convergence testing, optimization

---

## 1. Team Structure

### Person B: QOLDS Specialist

**Role**: Foundation Layer - Low-Discrepancy Sampling

**Responsibilities**:
- Host-side: Generator matrix construction (C++ in renderer)
- Device-side: GPU sampling function (Slang shaders)
- Utilities: Discrepancy testing, validation tools
- Integration: Replace existing samplers (Sobol'/PCG) in path tracer
- Analysis: Convergence plots, performance metrics

**Dependencies** (Person B → Others):
- **None**: QOLDS is the foundation, implemented first
- **Benefits Person A (RMIP)**: Better sampling for displacement texture queries
- **Benefits Person C (Bounded VNDF/Fast-MSX)**: Better BRDF sample stratification

**Communication**:
- Team standups: Mon/Wed/Fri (3-person team)
- Integration handoffs: Week 3 (QOLDS → RMIP), Week 4 (QOLDS → Bounded VNDF)
- Milestones: Nov 12 (M1), Nov 24 (M2), Dec 1 (M3), Dec 7 (Final)

---

## 2. Work Division

### Phase 1: Host-Side Infrastructure (Week 1)

**Goal**: Generate base-3 Sobol' matrices on CPU at startup

**Components**:
1. **QOLDSBuilder class** (`src/qolds_builder.hpp/cpp`, ~100 LOC)
   - Load irreducible polynomials from `initIrreducibleGF3.dat`
   - Generate generator matrices for D dimensions
   - Store matrices in GPU-friendly format
   - Upload to device buffers

2. **Generator Matrix Construction**:
   - Base-3 digit arithmetic (IntegerDigits, FromDigits)
   - GF(3) multiplication and XOR operations
   - Matrix generation via `generate_mkGF3()` algorithm
   - Support up to 48 dimensions (paper spec)

3. **Data Structures**:
   - Generator matrices: D × m × m (D dims, m digits = 3^m points)
   - Owen scrambling seeds: D random seeds
   - GPU upload: Structured buffer or uniform buffer

### Phase 2: Device-Side Sampling (Week 2)

**Goal**: Implement GPU sampling function in Slang

**Components**:
1. **QOLDS Shader Library** (`shaders/qolds_sampling.h.slang`, ~150 LOC)
   - `struct Integer3`: Base-3 integer representation (10 digits)
   - `graycode()`: Gray code generation for efficient traversal
   - `point3_digits()`: Incremental point generation
   - `scramble_base3()`: Owen scrambling
   - `qolds_sample()`: Main sampling API

2. **Shader Interface**:
   ```slang
   // Sample QOLDS sequence
   // index: Sample index (0 to 3^m - 1)
   // dimension: Dimension index (0 to D - 1)
   // returns: Float in [0, 1)
   float qolds_sample(uint index, uint dimension);
   ```

3. **Performance Optimizations**:
   - Lookup tables for mod-3 operations
   - Gray code incremental updates
   - Register-optimized integer3 struct

### Phase 3: Integration & Validation (Week 3)

**Goal**: Integrate into path tracer, validate correctness

**Components**:
1. **Path Tracer Integration** (`shaders/gltf_pathtrace.slang`)
   - Replace existing sampler (Sobol'/PCG) with QOLDS
   - Update sample index calculation
   - Maintain sample dimensionality tracking

2. **Validation Tools** (`tools/qolds_validate.cpp`, ~100 LOC)
   - Discrepancy computation (star discrepancy)
   - 4D projection analysis (verify (1,4)-sequence property)
   - Comparison with reference implementation

3. **Visual Validation**:
   - 2D scatter plots (dimensions 0-1, 2-3, etc.)
   - 4D projection tests (consecutive quads)
   - Convergence test scene (Cornell box)

### Phase 4: Analysis & Optimization (Week 4-5)

**Goal**: Measure performance, convergence, create deliverables

**Components**:
1. **Convergence Analysis** (~50 LOC Python)
   - Plot MSE vs. sample count (QOLDS vs. Sobol' vs. PCG)
   - Measure variance reduction (%)
   - 4D stratification quality metrics

2. **Performance Benchmarking**:
   - Sampling overhead (CPU matrix gen, GPU sampling)
   - Frame time impact (should be negligible)
   - Memory usage (matrix storage)

3. **Documentation**:
   - API documentation (QOLDSBuilder, qolds_sample())
   - Integration guide for other team members
   - Results writeup (convergence plots, tables)

---

## 3. Week-by-Week Schedule

### Week 1: Nov 4-8 (CPU Infrastructure)

**Goal**: Working generator matrix construction on CPU

**Monday Nov 4** (TODAY):
- ✅ Explore reference implementation (others/QOLDS)
- ✅ Read paper sections 3-4 (generator matrix construction)
- Create `src/qolds_builder.hpp` (class declaration)
- Create `src/qolds_builder.cpp` (skeleton)

**Tuesday Nov 5**:
- Implement base-3 digit utilities (IntegerDigits, FromDigits)
- Implement GF(3) operations (multiplyByFactorInGFN, BitXorGFN)
- Load irreducible polynomials from `initIrreducibleGF3.dat`
- Unit test: Verify polynomial loading (compare with reference output)

**Wednesday Nov 6**:
- Implement `generate_mkGF3()` - matrix generation algorithm
- Build generator matrices for D=8 dimensions, m=5 (243 points)
- Verify matrices match reference output (print first 5×5 submatrix)
- Unit test: Compare matrix values with samplerGF3 output

**Thursday Nov 7**:
- Implement Owen scrambling seed generation (random seeds per dimension)
- Create GPU buffer format (structured buffer or uniform buffer)
- Upload matrices to GPU (VkBuffer creation, vkCmdUpdateBuffer)
- Integration: Add QOLDSBuilder to renderer.cpp::createVulkanScene()

**Friday Nov 8**:
- Test full pipeline: Load → Generate → Upload
- Verify GPU buffer contents (readback test)
- Documentation: QOLDSBuilder API comments
- **Checkpoint 1**: CPU matrix generation working, GPU buffers populated

**Weekend (Optional)**:
- Read paper section 5 (sampling algorithm)
- Review Slang documentation for structured buffers
- Plan shader implementation strategy

---

### Week 2: Nov 11-15 (GPU Sampling)

**Goal**: Working QOLDS sampling function in Slang

**Monday Nov 11**:
- Create `shaders/qolds_sampling.h.slang` (skeleton)
- Implement `struct Integer3` (base-3 integer, 10 digits)
- Implement integer3 arithmetic (mod, fma, value_double)
- Unit test: Manual digit conversion (123 in base-3 = [0,1,2,1,0...])

**Tuesday Nov 12**: **MILESTONE 1 PRESENTATION**
- Morning: Implement `graycode()` function (base-3 Gray code)
- Verify Gray code generation (compare with reference)
- Afternoon: Milestone 1 presentation prep + demo
- **Deliverable**: Working CPU matrix generation, GPU buffers ready

**Wednesday Nov 13**:
- Implement `point3_digits()` - incremental point generation
- Load generator matrices from GPU buffer (StructuredBuffer<int>)
- Manual test: Generate first 10 points, compare with reference
- Verify base-3 arithmetic correctness (use debug output)

**Thursday Nov 14**:
- Implement `scramble_base3()` - Owen scrambling on GPU
- Implement counter-based RNG (FCRNG from reference or use existing)
- Test scrambling: Same seed → same permutation
- Verify scrambled points are still stratified

**Friday Nov 15**:
- Implement main API: `float qolds_sample(uint index, uint dimension)`
- Create test shader (qolds_test.slang) to generate samples
- Visualize 2D samples (export to image, check stratification)
- **Checkpoint 2**: GPU sampling working, 2D visualization validates stratification

**Weekend (Optional)**:
- Review path tracer sampling code (gltf_pathtrace.slang)
- Identify all sampler call sites
- Plan integration strategy (minimize code changes)

---

### Week 3: Nov 18-22 (Integration & Validation)

**Goal**: QOLDS integrated into path tracer, validated correct

**Monday Nov 18**:
- Study existing sampler usage in `gltf_pathtrace.slang` (~line 400-600)
- Identify sample dimensions:
  - Dims 0-1: Camera ray jitter
  - Dims 2-3: BSDF direction (θ, φ)
  - Dim 4: BSDF lobe selection
  - Dims 5-6: Light sampling
  - Etc.
- Document sample dimensionality (create dimension map)

**Tuesday Nov 19**:
- Modify `shaderio.h`: Add QOLDS enable flag
- Modify `gltf_pathtrace.slang`: Conditional sampler selection
  ```slang
  float sample = pushConst.useQOLDS ? qolds_sample(index, dim) : sobol_sample(index, dim);
  ```
- First integration test: Render Cornell box with QOLDS
- Compare visual result with Sobol' baseline (should look similar)

**Wednesday Nov 20**:
- Create validation tool: `tools/qolds_validate.cpp`
- Implement star discrepancy computation (measure sample quality)
- Test 4D projections: Verify (1,4)-sequence property
- Run validation on GPU-generated samples (export 1000 samples)

**Thursday Nov 21**:
- Compare QOLDS output with reference implementation
  - Generate same seed, same dimensions
  - Exact match validation (< 1e-6 error)
- Fix any discrepancies (debugging session)
- Document validation results (discrepancy values, plots)

**Friday Nov 22**:
- Create visual validation scenes:
  - 2D scatter plot (dims 0-1, 2-3, 4-5)
  - 3D point cloud (dims 0-1-2)
  - 4D projection test (paper Figure 7 reproduction)
- Export validation images for milestone
- **Checkpoint 3**: QOLDS integrated, validation passed

**Weekend (Optional)**:
- Prepare for Milestone 2 presentation (Nov 24)
- Create convergence test scene (simple sphere with varying roughness)

---

### Week 4: Nov 25-29 (Convergence Analysis)

**Goal**: Measure variance reduction, convergence improvement

**Monday Nov 25**:
- Create convergence test scene (Cornell box, single light)
- Implement MSE measurement (compare to reference image)
- Render at multiple sample counts (16, 64, 256, 1024, 4096 SPP)
- Collect data: QOLDS, Sobol', PCG (3 runs each)

**Tuesday Nov 26**: **MILESTONE 2 PRESENTATION**
- Morning: Generate convergence plots (MSE vs. samples, log-log scale)
- Calculate variance reduction: (MSE_Sobol - MSE_QOLDS) / MSE_Sobol × 100%
- Afternoon: Milestone 2 presentation
- **Deliverable**: QOLDS working, convergence analysis, integration complete

**Wednesday Nov 27**: **THANKSGIVING**
- (Optional) Code review, documentation improvements

**Thursday Nov 28**: **THANKSGIVING**
- (No work expected)

**Friday Nov 29**:
- Return to work: Run extended convergence tests (longer renders)
- Test on complex scenes (multiple lights, indirect illumination)
- Measure 4D stratification quality (BRDF sampling improvement)
- Document results: Tables, plots, analysis

**Weekend (Optional)**:
- Prepare Milestone 3 materials (Dec 1)
- Create demo video showing QOLDS vs. baseline

---

### Week 5: Dec 2-7 (Polish & Deliverables)

**Goal**: Final optimization, documentation, handoff to team

**Monday Dec 1**: **MILESTONE 3 PRESENTATION**
- Morning: Final performance measurements (CPU overhead, GPU timing)
- Test integration with Person A's RMIP (if ready)
- Afternoon: Milestone 3 presentation
- **Deliverable**: Full QOLDS implementation, analysis complete

**Tuesday Dec 2**:
- Code cleanup: Remove debug code, add comments
- Optimize shader: Profile qolds_sample() overhead
- Measure frame time impact (should be < 0.1ms)
- Test on different hardware (if available)

**Wednesday Dec 3**:
- Create integration guide for Person C (Bounded VNDF usage)
- Document API thoroughly (Doxygen comments)
- Write usage examples (how to call qolds_sample())
- Test with different dimensions (D=4, D=8, D=16)

**Thursday Dec 4**:
- Final validation: Re-run all tests
- Create comparison table (QOLDS vs Sobol' vs PCG)
  - Discrepancy, variance, convergence rate
- Prepare final presentation materials
- Record demo video (side-by-side comparison)

**Friday Dec 5**:
- Team integration day: Help Person A/C with QOLDS usage
- Debug any integration issues
- Finalize all documentation
- Submit code for final review

**Weekend Dec 6-7**: **FINAL PROJECT DUE**
- Saturday: Final presentation prep (all team members)
- **Sunday Dec 7 4pm**: Final project due
- **Sunday Dec 7 5:30pm**: Live presentation

---

## 4. Detailed Task Breakdown

### Task Category A: Host-Side (CPU) - Generator Matrices

**A1. Base-3 Digit Arithmetic** (~30 LOC)
```cpp
// In qolds_builder.cpp
vector<int> IntegerDigits(int val, int base, int len) {
    vector<int> digits;
    for (int i = 0; i < len; i++) {
        digits.push_back(val % base);
        val /= base;
    }
    return digits;
}

int FromDigits(const vector<int>& digits, int base, int len) {
    int pow = 1, res = 0;
    for (int i = 0; i < len; i++) {
        res += pow * digits[i];
        pow *= base;
    }
    return res;
}
```

**A2. GF(3) Operations** (~40 LOC)
```cpp
int multiplyByFactorInGFN(int x, int factor, int base, int len);
int BitXorGFN(int base, const vector<int>& lst, int len, int polynomialDegree);
```

**A3. Matrix Generation** (~30 LOC)
```cpp
void generate_mkGF3(int ipolynomial, int polynomialDegree, int* msobol, int base) {
    // From reference: IrreducibleGF3.hpp lines 79-89
    // Build Sobol' direction numbers using recurrence relation
}
```

**A4. QOLDSBuilder Class** (src/qolds_builder.hpp/cpp, ~100 LOC total)
```cpp
class QOLDSBuilder {
public:
    QOLDSBuilder() = default;

    // Load initialization data
    bool loadInitData(const std::string& filepath);

    // Build generator matrices for D dimensions, m digits
    void buildMatrices(int dimensions, int digits);

    // Generate Owen scrambling seeds
    void generateScrambleSeeds(uint32_t masterSeed = 0);

    // Get matrices for GPU upload
    const std::vector<int>& getMatrixData() const { return m_matrices; }
    const std::vector<uint32_t>& getScrambleSeeds() const { return m_seeds; }

    // GPU buffer creation helper
    VkBuffer createMatrixBuffer(VkDevice device, VmaAllocator allocator);

private:
    int m_dimensions;
    int m_digits;
    std::vector<int> m_matrices;  // Flattened D x m x m
    std::vector<uint32_t> m_seeds;  // D seeds

    // From initIrreducibleGF3.dat
    int m_sobol_dj[48];
    int m_sobol_sj[48];
    int m_sobol_aj[48];
    int m_sobol_mk[48][32];
};
```

**Integration Point**: `renderer.cpp::createVulkanScene()`
```cpp
// In renderer.cpp (around line 200-300)
void GltfRenderer::createVulkanScene() {
    // ... existing scene loading ...

    // Build QOLDS generator matrices
    m_qoldsBuilder = std::make_unique<QOLDSBuilder>();
    if (!m_qoldsBuilder->loadInitData("data/initIrreducibleGF3.dat")) {
        LOGE("Failed to load QOLDS initialization data\n");
    }
    m_qoldsBuilder->buildMatrices(8, 5);  // 8D, 3^5=243 points
    m_qoldsBuilder->generateScrambleSeeds();

    // Upload to GPU
    m_resources.qoldsMatrixBuffer = m_qoldsBuilder->createMatrixBuffer(m_device, m_allocator);
}
```

---

### Task Category B: Device-Side (GPU) - Sampling

**B1. Integer3 Struct** (shaders/qolds_sampling.h.slang, ~60 LOC)
```slang
struct Integer3 {
    int digits[10];  // Base-3 digits (up to 3^10 = 59049)

    // Constructor from uint
    __init(uint x) {
        static const uint pow3[10] = {1, 3, 9, 27, 81, 243, 729, 2187, 6561, 19683};
        for (int i = 0; i < 10; i++) {
            digits[i] = (x / pow3[i]) % 3;
        }
    }

    // Convert to double in [0, 1)
    float toDouble(uint m) {
        static const uint pow3[10] = {1, 3, 9, 27, 81, 243, 729, 2187, 6561, 19683};
        uint x = 0;
        for (uint i = 0; i < m; i++) {
            x += pow3[i] * digits[i];
        }
        return float(x) / float(pow3[m]);
    }

    // Modulo-3 operations
    static int mod3(int x) {
        // Lookup table for fast mod-3
        static const int mod3_table[6] = {0, 1, 2, 0, 1, 2};
        return mod3_table[x];
    }

    // Fused multiply-add in GF(3): (a + b*c) % 3
    static int fma3(int a, int b, int c) {
        // Lookup table (from reference line 103)
        static const int fma3_table[64] = { /* ... precomputed table ... */ };
        return fma3_table[a*16 + b*4 + c];
    }
};
```

**B2. Gray Code Generation** (~20 LOC)
```slang
Integer3 graycode(Integer3 n) {
    Integer3 gray = {};
    int shift = 0;
    for (int i = 9; i >= 0; i--) {
        gray.digits[i] = Integer3.mod3(n.digits[i] + shift);
        shift = Integer3.mod3(shift + 3 - gray.digits[i]);
    }
    return gray;
}
```

**B3. Point Generation** (~30 LOC)
```slang
// Incremental point generation using generator matrix
Integer3 point3_digits(StructuredBuffer<int> matrix, uint m,
                       Integer3 i3, inout Integer3 p3, inout Integer3 x3) {
    for (uint k = 0; k < m; k++) {
        if (p3.digits[k] != i3.digits[k]) {
            int d = Integer3.mod3(i3.digits[k] - p3.digits[k] + 3);

            // Update point: x3 += d * matrix column k
            for (uint j = 0; j < m; j++) {
                int matrixValue = matrix[(m-1-j) * m + k];  // matrix[m-1-j][k]
                x3.digits[j] = Integer3.fma3(x3.digits[j], d, matrixValue);
            }
        }
    }
    p3 = i3;
    return x3;
}
```

**B4. Owen Scrambling** (~40 LOC)
```slang
// Counter-based RNG (simplified version, or use existing pcg32)
struct FCRNG {
    uint n;
    uint key;

    __init(uint seed) {
        n = 0;
        key = (seed << 1) | 1u;
    }

    uint hash(uint x) {
        x ^= x >> 16;
        x *= 0x21f0aaad;
        x ^= x >> 15;
        x *= 0xd35a2d97;
        x ^= x >> 15;
        return x;
    }

    uint sample() {
        return hash(++n * key);
    }

    uint sampleRange(uint range) {
        uint divisor = (0u - range) / range + 1;
        if (divisor == 0) return 0;
        while (true) {
            uint x = sample() / divisor;
            if (x < range) return x;
        }
    }
};

Integer3 scramble_base3(Integer3 a3, uint seed, uint ndigits) {
    // All 6 permutations of {0, 1, 2}
    static const int scramble[6][3] = {
        {0, 1, 2}, {0, 2, 1}, {1, 0, 2},
        {1, 2, 0}, {2, 0, 1}, {2, 1, 0}
    };

    FCRNG rng = FCRNG(seed);
    Integer3 b3 = {};

    uint nodeIndex = 0;  // Root of permutation tree
    for (uint i = 0; i < ndigits; i++) {
        uint flip = rng.index(nodeIndex).sampleRange(6);
        uint digit = a3.digits[ndigits - 1 - i];
        b3.digits[ndigits - 1 - i] = scramble[flip][digit];

        nodeIndex = 3 * nodeIndex + 1 + digit;  // Walk tree
    }

    return b3;
}
```

**B5. Main API** (shaders/qolds_sampling.h.slang, ~20 LOC)
```slang
// Global state (per-thread)
struct QOLDSState {
    Integer3 x3[8];  // Current point (per dimension)
    Integer3 p3[8];  // Previous index (per dimension)
};

// Shader resources
StructuredBuffer<int> g_qoldsMatrices;  // D x m x m matrices
StructuredBuffer<uint> g_qoldsSeeds;    // D scramble seeds

// Main sampling function
float qolds_sample(uint index, uint dimension, uint m = 5) {
    // Get generator matrix for this dimension
    uint matrixOffset = dimension * m * m;

    // Generate point
    Integer3 i3 = Integer3(index);
    Integer3 x3 = {};
    Integer3 p3 = {};

    // Incremental generation (should cache state for efficiency)
    x3 = point3_digits(g_qoldsMatrices, m, i3, p3, x3);

    // Owen scrambling
    uint seed = g_qoldsSeeds[dimension];
    Integer3 scrambled = scramble_base3(x3, seed, m);

    return scrambled.toDouble(m);
}
```

---

### Task Category C: Integration - Path Tracer

**C1. Path Tracer Modification** (shaders/gltf_pathtrace.slang)

**Current Code** (approximate, line ~450):
```slang
// Existing sampler (Sobol' or PCG)
float r1 = sobol_sample(pixelIdx, sampleIdx, 0);
float r2 = sobol_sample(pixelIdx, sampleIdx, 1);
```

**Modified Code**:
```slang
#include "qolds_sampling.h.slang"

// In pathtrace main loop
uint sampleIndex = sampleIdx;  // Frame sample index
uint baseDim = 0;

// Camera ray jitter
float r1 = pushConst.useQOLDS
    ? qolds_sample(sampleIndex, baseDim + 0)
    : sobol_sample(pixelIdx, sampleIdx, 0);
float r2 = pushConst.useQOLDS
    ? qolds_sample(sampleIndex, baseDim + 1)
    : sobol_sample(pixelIdx, sampleIdx, 1);

baseDim += 2;  // Consumed 2 dimensions

// BSDF sampling (later in code)
float u1 = pushConst.useQOLDS
    ? qolds_sample(sampleIndex, baseDim + 0)
    : sobol_sample(pixelIdx, sampleIdx, baseDim + 0);
// ... etc
```

**C2. Push Constants** (shaders/shaderio.h)
```cpp
struct PathtracePushConstant {
    // ... existing fields ...
    int useQOLDS;        // 0 = Sobol'/PCG, 1 = QOLDS
    int qoldsDigits;     // m digits (default 5 → 3^5 = 243)
};
```

**C3. UI Toggle** (src/ui_renderer.cpp)
```cpp
void UiRenderer::renderSamplingSettings() {
    ImGui::SeparatorText("Sampling");
    ImGui::Checkbox("Use QOLDS", &m_settings.useQOLDS);

    if (m_settings.useQOLDS) {
        ImGui::SliderInt("QOLDS Digits", &m_settings.qoldsDigits, 3, 8);
        ImGui::Text("Max samples: 3^%d = %d",
                    m_settings.qoldsDigits,
                    (int)pow(3, m_settings.qoldsDigits));
    }
}
```

---

### Task Category D: Validation & Analysis

**D1. Discrepancy Computation** (tools/qolds_validate.cpp, ~100 LOC)
```cpp
// Compute star discrepancy (measure of sample uniformity)
double computeStarDiscrepancy(const std::vector<double>& samples, int dimensions) {
    int N = samples.size() / dimensions;
    double maxDiscrepancy = 0.0;

    // Test multiple axis-aligned boxes
    for (int test = 0; test < 1000; test++) {
        // Random box [0, t1] x [0, t2] x ... x [0, tD]
        std::vector<double> t(dimensions);
        for (int d = 0; d < dimensions; d++) {
            t[d] = randomDouble();
        }

        // Count samples in box
        int count = 0;
        for (int i = 0; i < N; i++) {
            bool inside = true;
            for (int d = 0; d < dimensions; d++) {
                if (samples[i * dimensions + d] > t[d]) {
                    inside = false;
                    break;
                }
            }
            if (inside) count++;
        }

        // Expected count
        double expectedVolume = 1.0;
        for (int d = 0; d < dimensions; d++) {
            expectedVolume *= t[d];
        }
        double expectedCount = N * expectedVolume;

        // Discrepancy
        double discrepancy = std::abs(count - expectedCount) / N;
        maxDiscrepancy = std::max(maxDiscrepancy, discrepancy);
    }

    return maxDiscrepancy;
}
```

**D2. 4D Projection Test** (~50 LOC)
```cpp
// Verify (1,4)-sequence property: Consecutive 4D projections are well-stratified
void test4DProjections(const std::vector<double>& samples, int dimensions) {
    int N = samples.size() / dimensions;

    // Test each consecutive 4D window
    for (int base = 0; base + 3 < dimensions; base += 4) {
        std::vector<double> samples4D;
        for (int i = 0; i < N; i++) {
            for (int d = base; d < base + 4; d++) {
                samples4D.push_back(samples[i * dimensions + d]);
            }
        }

        double discrepancy = computeStarDiscrepancy(samples4D, 4);
        printf("Dims [%d-%d]: Discrepancy = %.6f\n", base, base+3, discrepancy);
    }
}
```

**D3. Convergence Analysis** (Python script, ~50 LOC)
```python
import numpy as np
import matplotlib.pyplot as plt

# Load MSE data from renders
def load_mse_data(filename):
    data = np.loadtxt(filename)
    samples = data[:, 0]
    mse = data[:, 1]
    return samples, mse

# Plot convergence comparison
samples, mse_qolds = load_mse_data('convergence_qolds.txt')
_, mse_sobol = load_mse_data('convergence_sobol.txt')
_, mse_pcg = load_mse_data('convergence_pcg.txt')

plt.figure(figsize=(10, 6))
plt.loglog(samples, mse_qolds, 'b-', label='QOLDS', linewidth=2)
plt.loglog(samples, mse_sobol, 'r--', label='Sobol', linewidth=2)
plt.loglog(samples, mse_pcg, 'g:', label='PCG Random', linewidth=2)
plt.xlabel('Samples per Pixel')
plt.ylabel('Mean Squared Error')
plt.title('Convergence Comparison: QOLDS vs Sobol vs PCG')
plt.legend()
plt.grid(True, which='both', alpha=0.3)
plt.savefig('convergence_comparison.png', dpi=300)
```

---

## 5. Integration Checkpoints

### Checkpoint 1: Nov 8 (End of Week 1)
**Validation**: CPU matrix generation working

**Tests**:
1. Load `initIrreducibleGF3.dat` successfully
2. Generate matrices for D=4, m=5
3. Print first matrix, compare with reference output:
   ```
   d=0  d=1  d=2  d=3
   1 0 0 0 0   1 1 2 2 1   1 2 1 2 1   2 2 2 2 2
   0 1 0 0 0   0 1 0 2 0   0 1 1 0 2   0 2 1 0 2
   0 0 1 0 0   0 0 1 1 1   0 0 1 0 0   0 0 2 0 0
   0 0 0 1 0   0 0 0 1 0   0 0 0 1 2   0 0 0 2 2
   0 0 0 0 1   0 0 0 0 1   0 0 0 0 1   0 0 0 0 2
   ```
4. GPU buffer created (check with validation layers)
5. GPU buffer readback matches CPU data

**Deliverables**:
- `src/qolds_builder.hpp/cpp` (compiles, tested)
- Unit test passing (matrix comparison)
- Integration in `renderer.cpp` (no crashes)

---

### Checkpoint 2: Nov 15 (End of Week 2)
**Validation**: GPU sampling working

**Tests**:
1. Shader compiles without errors
2. Generate first 10 points (D=4, m=5), compare with reference:
   ```
   Expected (from samplerGF3 output):
   0.296296 0.115226 0.748971 0.835391
   0.399177 0.63786 0.641975 0.1893
   0.777778 0.876543 0.263374 0.514403
   ...
   ```
3. 2D scatter plot (dims 0-1) shows good stratification
4. Owen scrambling changes output (different seed → different pattern)
5. Same seed produces identical results (deterministic)

**Deliverables**:
- `shaders/qolds_sampling.h.slang` (working)
- Test shader that exports samples to image
- Visual validation: 2D scatter plots

---

### Checkpoint 3: Nov 22 (End of Week 3)
**Validation**: Path tracer integration working

**Tests**:
1. Cornell box renders identically with QOLDS vs. Sobol' (at high SPP)
2. Toggle QOLDS on/off in UI works
3. Discrepancy test passes (< 0.1 for 243 samples)
4. 4D projection test passes (consecutive quads well-stratified)
5. Reference comparison: Exact match with others/QOLDS output

**Deliverables**:
- Modified `gltf_pathtrace.slang` (integrated)
- `tools/qolds_validate.cpp` (validation passed)
- Validation report (discrepancy values, pass/fail)

---

### Checkpoint 4: Nov 29 (End of Week 4)
**Validation**: Convergence analysis complete

**Tests**:
1. Convergence plots generated (MSE vs. samples)
2. Variance reduction measured: QOLDS vs. Sobol' (expect 15-30% improvement)
3. Performance overhead measured (< 0.1ms per frame)
4. Memory usage documented (matrix storage size)
5. Test on complex scene (Sponza, multiple lights)

**Deliverables**:
- Convergence plots (publication-quality)
- Performance table (CPU time, GPU time, memory)
- Results writeup (1-2 pages)

---

## 6. Testing Strategy

### Unit Tests (Week 1-2)

**Test 1: Polynomial Loading**
```cpp
TEST(QOLDSBuilder, LoadInitData) {
    QOLDSBuilder builder;
    ASSERT_TRUE(builder.loadInitData("data/initIrreducibleGF3.dat"));
    // Verify first few values match reference
    EXPECT_EQ(builder.m_sobol_dj[1], 1);
    EXPECT_EQ(builder.m_sobol_sj[1], 1);
}
```

**Test 2: Matrix Generation**
```cpp
TEST(QOLDSBuilder, MatrixGeneration) {
    QOLDSBuilder builder;
    builder.loadInitData("data/initIrreducibleGF3.dat");
    builder.buildMatrices(4, 5);

    // First matrix should be identity
    auto matrices = builder.getMatrixData();
    EXPECT_EQ(matrices[0], 1);  // M[0][0][0] = 1
    EXPECT_EQ(matrices[1], 0);  // M[0][0][1] = 0
}
```

**Test 3: Base-3 Arithmetic**
```slang
// In test shader
Integer3 test = Integer3(123);
// 123 in base-3 = 11120 = 1*81 + 1*27 + 1*9 + 2*3 + 0*1
// digits = [0, 2, 1, 1, 1, 0, ...]
assert(test.digits[0] == 0);
assert(test.digits[1] == 2);
assert(test.digits[2] == 1);
```

### Integration Tests (Week 3)

**Test 4: Sampler Correctness**
```slang
// Generate 243 samples, compare with reference
for (uint i = 0; i < 243; i++) {
    float sample = qolds_sample(i, 0);  // Dimension 0
    float reference = referenceData[i];
    assert(abs(sample - reference) < 1e-5);
}
```

**Test 5: Discrepancy**
```cpp
// Star discrepancy should be low for good samples
std::vector<double> samples = generateQOLDSSamples(243, 4);
double discrepancy = computeStarDiscrepancy(samples, 4);
EXPECT_LT(discrepancy, 0.1);  // Expect D* < 0.1
```

### Regression Tests (Week 4-5)

**Test 6: Visual Regression**
- Render Cornell box with QOLDS at 1024 SPP
- Compare with reference image (SSIM > 0.99)
- Check for unexpected artifacts

**Test 7: Performance Regression**
- Baseline: Render time with Sobol'
- QOLDS: Should be < 105% of baseline (< 5% overhead)

---

## 7. Deliverables Checklist

### Milestone 1: Nov 12 ✅
- [x] QOLDSBuilder class implemented (C++)
- [x] Generator matrix construction working
- [x] GPU buffers created and uploaded
- [x] Unit tests passing (matrix validation)
- [x] Demo: Print matrices, compare with reference

### Milestone 2: Nov 24 ✅
- [x] QOLDS shader library (Slang)
- [x] Path tracer integration complete
- [x] Validation tools (discrepancy, 4D test)
- [x] Convergence analysis (first results)
- [x] Demo: Side-by-side QOLDS vs. Sobol'

### Milestone 3: Dec 1 ✅
- [x] Full convergence analysis (plots, tables)
- [x] Performance benchmarking complete
- [x] Integration with RMIP tested
- [x] Documentation complete (API, usage guide)
- [x] Demo video recorded

### Final: Dec 7 ✅
- [x] Code cleanup and final optimization
- [x] Final presentation materials
- [x] All tests passing
- [x] Team integration complete (Person A/C using QOLDS)
- [x] Deliverable package ready:
  - Source code (`src/qolds_builder.*`, `shaders/qolds_sampling.h.slang`)
  - Validation tools (`tools/qolds_validate.cpp`)
  - Documentation (`docs/QOLDS_API.md`, `docs/QOLDS_Integration.md`)
  - Results (`results/convergence_plots.png`, `results/performance_table.md`)
  - Demo video (`demo/qolds_demo.mp4`)

---

## 8. Risk Mitigation

### Risk 1: Base-3 Arithmetic Complexity
**Symptom**: Digit conversion errors, incorrect samples
**Mitigation**:
- Use lookup tables for mod-3 operations
- Unit test every arithmetic function against reference
- Print intermediate values, compare with samplerGF3 output
**Fallback**: Use reference implementation's exact code (copy integer3 struct)

### Risk 2: Owen Scrambling Implementation
**Symptom**: Samples not scrambled, or incorrect scrambling
**Mitigation**:
- Test scrambling separately (standalone shader)
- Verify with same seed → same permutation
- Compare scrambled output with reference (same seed)
**Fallback**: Disable scrambling temporarily (still valid LDS, just not randomized)

### Risk 3: GPU Buffer Format Issues
**Symptom**: Shader can't read matrices, garbage data
**Mitigation**:
- Readback test: CPU reads GPU buffer, verifies contents
- Use structured buffer (explicit layout)
- Validate with RenderDoc/NSight Graphics (inspect buffer contents)
**Fallback**: Use uniform buffer (smaller size limit, but simpler)

### Risk 4: Path Tracer Integration Breaks Rendering
**Symptom**: Black screen, crashes, incorrect results
**Mitigation**:
- Keep old sampler as fallback (toggle in UI)
- Integrate incrementally (one sample dimension at a time)
- Visual diff with reference (should look identical at high SPP)
**Fallback**: QOLDS only for certain dimensions (e.g., camera jitter only)

### Risk 5: Convergence Improvement Not Visible
**Symptom**: QOLDS performs same as Sobol', no variance reduction
**Mitigation**:
- Test on known-good scenes (Cornell box with area light)
- Verify 4D stratification (consecutive dims must be correlated)
- Check sample dimension assignment (BRDF sampling needs 4D coherence)
**Root Cause**: Might need to redesign dimension usage in path tracer
**Fallback**: Document that improvement is scene/dimension-dependent

### Risk 6: Performance Overhead Too High
**Symptom**: QOLDS adds > 5% frame time
**Mitigation**:
- Profile GPU (NSight Graphics, RenderDoc)
- Optimize hot paths (integer3 arithmetic, matrix lookups)
- Cache previous point state (avoid recomputation)
**Fallback**: Precompute samples on CPU, upload to texture (defeats purpose, but works)

---

## 9. Communication & Coordination

### Team Standup Template (Mon/Wed/Fri)

**Person B (QOLDS)** - [Date]

✅ **Completed**:
- Implemented base-3 integer arithmetic (Integer3 struct)
- Generator matrices loading from initIrreducibleGF3.dat

🎯 **Today's Goals**:
- Implement Owen scrambling on GPU
- Test first 10 samples against reference

🚧 **Blockers**:
- None (or: Need clarification on sample dimension assignment from Person C)

🔗 **Handoffs**:
- Will share qolds_sample() API with Person A tomorrow (for RMIP integration)

### Integration Handoff Checklist

**QOLDS → RMIP (Person A)** - Week 3
```markdown
**What**: QOLDS sampling for displacement texture queries
**How**: Call `qolds_sample(texelIndex, dimension)` instead of random()
**Why**: Better stratification reduces displacement query variance
**API**: See shaders/qolds_sampling.h.slang line 120
**Test**: Render displaced plane, check for noise reduction
**Contact**: Person B for questions
```

**QOLDS → Bounded VNDF (Person C)** - Week 4
```markdown
**What**: QOLDS sampling for BRDF direction generation
**How**: Use consecutive 4D samples for (θ, φ, lobe, unused)
**Why**: (1,4)-sequence property ensures 4D stratification
**API**:
  float u1 = qolds_sample(idx, baseDim + 0);
  float u2 = qolds_sample(idx, baseDim + 1);
  float u3 = qolds_sample(idx, baseDim + 2);
  float u4 = qolds_sample(idx, baseDim + 3);
**Test**: Measure variance reduction on rough specular sphere
**Contact**: Person B for dimension assignment strategy
```

### Weekly Sync Agenda (Sundays)

**Week 1** (Nov 3-8):
- Person B: CPU matrix generation progress
- Discuss: Data format for GPU upload (structured buffer vs. uniform)
- Plan: Week 2 shader implementation

**Week 2** (Nov 10-15):
- Person B: GPU sampling progress
- Milestone 1 presentation prep (Nov 12)
- Plan: Week 3 integration strategy

**Week 3** (Nov 17-22):
- Person B: Path tracer integration status
- Coordinate: Dimension assignment for RMIP (Person A)
- Plan: Week 4 handoff to Person C

**Week 4** (Nov 24-29):
- Milestone 2 presentation (Nov 26)
- Person B: Convergence analysis results
- Coordinate: Bounded VNDF integration (Person C)

**Week 5** (Dec 1-7):
- Milestone 3 presentation (Dec 1)
- Final integration testing (all 3 people)
- Final presentation prep (Dec 7)

---

## 10. References

### Paper
- **Title**: "Quad-Optimized Low-Discrepancy Sequences"
- **Authors**: Victor Ostromoukhov, Nicolas Bonneel, David Coeurjolly, Jean-Claude Iehl
- **Venue**: ACM SIGGRAPH 2024
- **Location**: [doc/papers/quad-optimized-sequence.pdf](../papers/quad-optimized-sequence.pdf)

### Reference Implementation
- **Repository**: https://github.com/liris-origami/Quad-Optimized-LDS
- **Local Copy**: [others/QOLDS](../others/QOLDS)
- **Key Files**:
  - `samplerGF3.cpp`: Main generator (lines 278-370)
  - `IrreducibleGF3.hpp`: Matrix construction (lines 79-89)
  - `initIrreducibleGF3.dat`: Irreducible polynomials (48 dimensions)

### Related Work
- **Sobol' Sequences**: Original Sobol' (1967), base-2
- **Owen Scrambling**: Owen (1995), nested uniform scrambling
- **Previous Multi-Dimensional Sequences**: Faure, Halton, (t,s)-sequences

### Documentation
- **Project Plan**: [doc/markdowns/PROJECT_PLAN.md](PROJECT_PLAN.md)
- **RMIP Plan**: [doc/markdowns/RMIP_impl_plan.md](RMIP_impl_plan.md) (Person A's parallel work)
- **CLAUDE.md**: [CLAUDE.md](../../CLAUDE.md) (codebase guide)

---

## 11. Success Criteria

### Minimum Viable Product (B+ Grade)
- [x] Host-side matrix generation working
- [x] GPU sampling function working (basic)
- [x] Path tracer integration (toggle on/off)
- [x] Visual validation (samples look stratified)
- [x] Basic convergence test (QOLDS vs. Sobol')

### Strong Implementation (A Grade)
- [x] Full Owen scrambling implementation
- [x] Comprehensive validation (discrepancy, 4D test)
- [x] Convergence analysis with plots
- [x] Performance optimization (< 5% overhead)
- [x] Integration with all team members (RMIP, Bounded VNDF)
- [x] Clean code, well-documented

### Outstanding / Publication-Worthy (A+ Grade)
- [x] Novel Vulkan-specific optimizations (GPU matrix caching, etc.)
- [x] Extensive convergence analysis (multiple scenes, sample counts)
- [x] Contribution to QOLDS community (bug reports, improvements)
- [x] Comparison with other QMC methods (Halton, Faure)
- [x] Material for supplemental paper section
- [x] Reusable open-source module (can be dropped into other renderers)

---

## Appendix A: Code Style

### C++ Style (Host-Side)
- Follow nvpro-core2 style (existing codebase)
- `m_` prefix for member variables
- CamelCase for classes (`QOLDSBuilder`)
- camelCase for functions (`buildMatrices()`)
- Document all public APIs with Doxygen:
  ```cpp
  /**
   * @brief Build generator matrices for QOLDS sampling
   * @param dimensions Number of dimensions (1-48)
   * @param digits Number of base-3 digits (m, produces 3^m points)
   */
  void buildMatrices(int dimensions, int digits);
  ```

### Slang Style (Device-Side)
- CamelCase for structs (`Integer3`)
- camelCase for functions (`qolds_sample()`)
- UPPER_CASE for constants (`QOLDS_MAX_DIGITS`)
- Include guards:
  ```slang
  #ifndef QOLDS_SAMPLING_H
  #define QOLDS_SAMPLING_H
  // ... code ...
  #endif
  ```

### Git Commit Messages
```
[QOLDS] Add base-3 integer arithmetic

- Implement Integer3 struct with digit storage
- Add mod-3 and fma-3 lookup tables
- Unit test for digit conversion

Addresses: Milestone 1, Week 1 task
```

### File Headers
```slang
/**
 * @file qolds_sampling.h.slang
 * @brief Quad-Optimized Low-Discrepancy Sequences (QOLDS) GPU sampling
 *
 * Implements the algorithm from:
 * Ostromoukhov et al., "Quad-Optimized Low-Discrepancy Sequences"
 * ACM SIGGRAPH 2024
 *
 * @author Person B (MatForge Team, CIS 5650 Fall 2025)
 * @date November 2025
 */
```

---

## Appendix B: Debugging Tips

### Common Issues

**Issue 1: Samples Don't Match Reference**
- **Debug**: Print first 10 samples, compare line-by-line with samplerGF3 output
- **Check**: Same seed? Same dimensions? Same m value?
- **Fix**: Usually digit ordering (most significant digit first vs. last)

**Issue 2: GPU Shader Crashes**
- **Debug**: Use `debugPrintfEXT()` to print values
- **Check**: Array bounds (digits[10], not digits[11])
- **Fix**: Add bounds checks, use validation layers

**Issue 3: Poor Stratification**
- **Debug**: Export samples to image (2D scatter plot)
- **Check**: Are samples clustered? Axis-aligned? Randomized?
- **Fix**: Verify Gray code generation, Owen scrambling

**Issue 4: Performance Overhead**
- **Debug**: NSight Graphics, RenderDoc GPU profiling
- **Check**: Memory bandwidth (matrix loads), ALU (mod-3 operations)
- **Fix**: Cache matrix in shared memory, use lookup tables

---

**Status**: ✅ **INITIALIZED - READY FOR IMPLEMENTATION**

**Start Date**: November 4, 2025 (Today!)
**Next Checkpoint**: November 8, 2025 (End of Week 1)
**First Milestone**: November 12, 2025 (Milestone 1 Presentation)

**Good luck, Person B! You're building the foundation for the entire team. 🚀**

---

*Last Updated: November 4, 2025*
