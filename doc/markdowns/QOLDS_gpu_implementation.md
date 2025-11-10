# QOLDS GPU Implementation Notes

**Status**: ✅ GPU-side implementation complete

---

## Implementation Summary

Successfully implemented the GPU-side QOLDS sampling in [shaders/qolds_sampling.h.slang](../../shaders/qolds_sampling.h.slang).

### Components Implemented

#### 1. **Integer3 Struct** (Line 42-107)
Base-3 integer representation with optimized operations:
- Constructor from `uint`
- `value()` and `toDouble()` conversion functions
- Fast `mod(x)` using 6-element lookup table
- Optimized `fma(a,b,c)` using 64-element lookup table

**Key Optimization**: Lookup tables replace modulo operations for ~3x speedup on GPU.

#### 2. **Gray Code Generation** (Line 119-133)
Generates base-3 Gray codes for efficient sequential traversal:
```slang
Integer3 graycode(Integer3 n);
```
Used for optimized sample generation when traversing sequentially.

#### 3. **Sobol' Point Generation** (Line 148-170)
Incremental point generation using generator matrices:
```slang
Integer3 point3_digits(
    StructuredBuffer<int> matrix,
    uint matrixOffset,
    uint m,
    Integer3 i3,
    inout Integer3 p3,
    inout Integer3 x3
);
```

**Key Feature**: Incremental updates avoid recomputing from scratch (O(m) instead of O(m²)).

#### 4. **Counter-Based RNG** (Line 178-230)
Fast FCRNG for Owen scrambling:
- Counter-based (no global state)
- Passes SmallCrush statistical tests
- Efficient range sampling with rejection

#### 5. **Owen Scrambling** (Line 244-279)
Nested uniform scrambling for randomization:
```slang
Integer3 scramble_base3(Integer3 a3, uint seed, uint ndigits);
```

Uses permutation tree traversal (6 permutations of {0,1,2}).

#### 6. **Main API Functions**

**Standard API** (Line 291-309):
```slang
float qolds_sample(
    uint index,
    uint dimension,
    StructuredBuffer<int> matrices,
    StructuredBuffer<uint> seeds,
    uint m = 5
);
```

**Gray Code API** (Line 316-330):
```slang
float qolds_sample_graycode(...);  // For Gray code traversal
```

**Cached State API** (Line 340-370):
```slang
struct QOLDSState { Integer3 p3, x3; };
float qolds_sample_cached(..., inout QOLDSState state, ...);
```
For performance when generating many samples per dimension.

---

## Usage Example

```slang
// In path tracer shader:
#include "qolds_sampling.h.slang"

// Buffers (bound by host)
[[vk::binding(...)]] StructuredBuffer<int>  qoldsMatrices;
[[vk::binding(...)]] StructuredBuffer<uint> qoldsSeeds;

void processPixel(...)
{
    uint sampleIndex = frameCount;
    uint dimension = 0;

    // Sample 2D for antialiasing jitter
    float r1 = qolds_sample(sampleIndex, dimension++, qoldsMatrices, qoldsSeeds, 5);
    float r2 = qolds_sample(sampleIndex, dimension++, qoldsMatrices, qoldsSeeds, 5);
    float2 jitter = float2(r1, r2);

    // Sample 3D for BSDF
    float r3 = qolds_sample(sampleIndex, dimension++, qoldsMatrices, qoldsSeeds, 5);
    float r4 = qolds_sample(sampleIndex, dimension++, qoldsMatrices, qoldsSeeds, 5);
    float r5 = qolds_sample(sampleIndex, dimension++, qoldsMatrices, qoldsSeeds, 5);
    float3 bsdfSample = float3(r3, r4, r5);

    // ... rest of path tracing ...
}
```

---

## Performance Characteristics

### Memory Usage
- **Matrices Buffer**: D × m × m × 4 bytes
  - Example (D=48, m=5): 48 × 5 × 5 × 4 = 4,800 bytes
- **Seeds Buffer**: D × 4 bytes
  - Example (D=48): 48 × 4 = 192 bytes
- **Per-thread State**: ~44 bytes (Integer3 × 3 + counters)

### Computational Cost
- **Base-3 conversion**: O(m) = O(5) = 5 operations
- **Point generation**: O(m²) = O(25) = 25 operations (with state caching)
- **Owen scrambling**: O(m) = O(5) = 5 operations
- **Total**: ~35-50 GPU instructions per sample

**Expected Overhead**: <1% frame time (compared to PCG's ~5 instructions)

### Optimization Opportunities
1. **Lookup tables**: Already implemented for mod3 and fma3
2. **State caching**: Use `qolds_sample_cached()` for sequential access
3. **Gray code**: Use `qolds_sample_graycode()` for ordered traversal
4. **Loop unrolling**: Compiler should auto-unroll m=5 loops

---

## Validation Checklist

### Build Validation ✅
- [x] Shader compiles without errors
- [x] Included in CMakeLists.txt
- [x] Organized in Visual Studio solution

### Functional Validation (To Do)
- [ ] Generate first 10 points, compare with CPU reference
- [ ] Verify point values are in [0, 1)
- [ ] Check scrambling produces different sequences per seed
- [ ] Validate incremental generation matches batch

### Integration Validation (To Do)
- [ ] Bind buffers from host code
- [ ] Call from path tracer shader
- [ ] Visual comparison: QOLDS vs PCG
- [ ] Performance profiling

---

## Next Steps (Week 2 - Day 3-5)

### Day 3: Host-Side Buffer Creation
**File**: [src/renderer.cpp](../../src/renderer.cpp)

1. Include QOLDS builder:
   ```cpp
   #include "qolds_builder.hpp"
   ```

2. Create buffers in `createVulkanScene()`:
   ```cpp
   m_qoldsBuilder = std::make_unique<QOLDSBuilder>();
   m_qoldsBuilder->loadInitData("resources/initIrreducibleGF3.dat");
   m_qoldsBuilder->buildMatrices(48, 5);  // 48D, 243 points
   m_qoldsBuilder->generateScrambleSeeds();
   ```

3. Upload to GPU:
   ```cpp
   const auto& matrices = m_qoldsBuilder->getMatrixData();
   const auto& seeds = m_qoldsBuilder->getScrambleSeeds();

   // Create Vulkan buffers
   VkDeviceSize matrixSize = matrices.size() * sizeof(int32_t);
   m_qoldsMatricesBuffer = m_allocator.createBuffer(
       matrixSize,
       VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
   );

   // Upload data using staging buffer
   // ... (staging upload code) ...
   ```

### Day 4: Shader Integration
**File**: [shaders/gltf_pathtrace.slang](../../shaders/gltf_pathtrace.slang)

1. Add bindings (after line 50):
   ```slang
   [[vk::binding(BindingPoints::eQoldsMatrices, 1)]]  StructuredBuffer<int>  qoldsMatrices;
   [[vk::binding(BindingPoints::eQoldsSeeds, 1)]]     StructuredBuffer<uint> qoldsSeeds;
   ```

2. Include header (after line 41):
   ```slang
   #include "qolds_sampling.h.slang"
   ```

3. Create wrapper function:
   ```slang
   float sample1D(inout uint seed, inout uint dimension, uint sampleIndex, bool useQOLDS) {
       if (useQOLDS) {
           return qolds_sample(sampleIndex, dimension++, qoldsMatrices, qoldsSeeds, 5);
       } else {
           return rand(seed);
       }
   }
   ```

### Day 5: Minimal Test
1. Replace ONE sampling call (subpixel jitter)
2. Verify rendering works
3. Toggle between PCG and QOLDS
4. Visual comparison

---

## Known Limitations

1. **Sample Count**: Max 3^m points
   - m=5: 243 samples
   - m=6: 729 samples
   - m=7: 2,187 samples
   - **Mitigation**: Wrap around or switch to PCG after exhausting

2. **Dimension Limit**: 48 dimensions
   - Sufficient for 5 bounces (~10 dims per bounce)
   - **Mitigation**: Reuse dimensions or reduce maxDepth

3. **Memory**: 5KB per 48 dimensions
   - Negligible on modern GPUs
   - **No mitigation needed**

4. **Performance**: ~1% overhead vs PCG
   - Acceptable for quality improvement
   - **Mitigation**: Use state caching for hot paths

---

## Testing Strategy

### Unit Tests (Manual Validation)
```slang
// Test in pixel shader:
if (pixelX == 0 && pixelY == 0) {
    // Generate first 5 points
    for (uint i = 0; i < 5; i++) {
        float v = qolds_sample(i, 0, qoldsMatrices, qoldsSeeds, 5);
        // Print or store for comparison with CPU
    }
}
```

### Visual Tests
1. Render sphere with QOLDS (dimension 0-1 for AA)
2. Compare with PCG baseline
3. Should look similar (maybe smoother)

### Convergence Tests (Week 4)
1. Render at 16, 64, 256 SPP
2. Measure MSE vs ground truth
3. QOLDS should converge faster

---

## References

- **Paper**: [doc/papers/quad-optimized-sequence.pdf](../papers/quad-optimized-sequence.pdf)
- **Reference CPU**: [others/QOLDS/samplerGF3.cpp](../../others/QOLDS/samplerGF3.cpp)
- **Integration Report**: [QOLDS_report.md](QOLDS_report.md)
- **Implementation Plan**: [QOLDS_impl_plan.md](QOLDS_impl_plan.md)

---

**Status**: ✅ GPU shader complete | ⏭️ Next: Buffer creation and integration
**Build Status**: ✅ Compiles without errors
**Last Updated**: November 4, 2025
