# RMIP Memory Investigation Report

## Issue Summary

When loading scenes with 3+ displacement maps (512x512) or 1+ displacement maps (1024x1024), the RMIP builder fails with:
```
VK_ERROR_OUT_OF_POOL_MEMORY from rmip_builder.cpp:468
```

This error occurs during the third material's RMIP build in `bindExpandResources()` when calling `vkAllocateDescriptorSets()`.

## Root Cause Analysis

### Problem 1: Descriptor Pool Size Insufficient

The descriptor pool is created in `RmipBuilder::init()` (line 27-43):

```cpp
std::vector<VkDescriptorPoolSize> initPoolSizes = m_initBindings.calculatePoolSizes();
std::vector<VkDescriptorPoolSize> expandPoolSizes = m_expandBindings.calculatePoolSizes();

// Combine pool sizes
std::vector<VkDescriptorPoolSize> poolSizes;
poolSizes.insert(poolSizes.end(), initPoolSizes.begin(), initPoolSizes.end());
poolSizes.insert(poolSizes.end(), expandPoolSizes.begin(), expandPoolSizes.end());

VkDescriptorPoolCreateInfo poolInfo{
    .maxSets = 200,  // <-- KEY ISSUE: maxSets
    .poolSizeCount = uint32_t(poolSizes.size()),
    .pPoolSizes = poolSizes.data(),
};
```

**The Issue:** `calculatePoolSizes()` returns descriptor counts for a *single* descriptor set, not scaled by `maxSets`. The pool sizes should be:

| Descriptor Type | Init Bindings | Expand Bindings | Per-Set Total | Needed for 200 Sets |
|-----------------|---------------|-----------------|---------------|---------------------|
| SAMPLED_IMAGE   | 1             | 0               | 1             | 200                 |
| STORAGE_IMAGE   | 1             | 2               | 3             | 600                 |
| UNIFORM_BUFFER  | 1             | 1               | 2             | 400                 |

**Current Pool Sizes (approximate):**
- SAMPLED_IMAGE: 1 (only enough for 1 init set!)
- STORAGE_IMAGE: 3 (only enough for ~1 set!)
- UNIFORM_BUFFER: 2 (only enough for 2 sets!)

### Problem 2: Number of Descriptor Sets per RMIP Build

For a 512x512 texture:
- `maxLevel = log2(512) = 9`
- `numLayers = (9+1)² = 100`

The build process allocates descriptor sets as follows:

1. **Init Phase**: 1 descriptor set (for `bindInitResources`)
2. **Expand Phase**: Iterates over all (p, q) pairs where `p + q = level` for `level = 1..18`:

| Level | Pairs (p,q) | Dispatches |
|-------|-------------|------------|
| 1     | (0,1), (1,0) | 2 |
| 2     | (0,2), (1,1), (2,0) | 3 |
| 3     | (0,3), (1,2), (2,1), (3,0) | 4 |
| ...   | ... | ... |
| 9     | (0,9), (1,8), ..., (9,0) | 10 |
| 10    | (1,9), (2,8), ..., (9,1) | 9 |
| ...   | ... | ... |
| 18    | (9,9) | 1 |

**Total dispatches per 512x512 RMIP:** 1 (init) + 99 (expand) = **100 descriptor sets**

For a 1024x1024 texture:
- `maxLevel = 10`
- **Total:** 1 + 120 = **121 descriptor sets**

### Why It Fails

| Scenario | Descriptor Sets Needed | Pool Limit | Result |
|----------|------------------------|------------|--------|
| 1× 512x512 | 100 | 200 | ✅ Works |
| 2× 512x512 | 200 | 200 | ✅ Works (barely) |
| 3× 512x512 | 300 | 200 | ❌ **FAILS** |
| 1× 1024x1024 | 121 | 200 | ✅ Works |
| 2× 1024x1024 | 242 | 200 | ❌ **FAILS** |

Note: Even with sufficient `maxSets`, the pool would still fail because the **pool sizes** (descriptor counts) are not scaled properly.

## Memory Usage Context

This is NOT a VRAM issue. The error is specifically about **descriptor pool exhaustion**, not GPU memory:

- 1 RMIP at 512x512 with 100 layers uses ~100 MB (512 × 512 × 100 × 8 bytes per float2)
- Your RTX 5080 has 16 GB VRAM - plenty of capacity
- Task Manager shows ~1 GB usage because this is descriptor pool capacity, not memory

## Recommended Fixes

### Fix 1: Scale Pool Sizes by maxSets (Recommended)

```cpp
void RmipBuilder::init(...)
{
    // ...

    // Calculate pool sizes scaled by maxSets
    uint32_t maxSets = 500;  // Increased for more materials

    std::vector<VkDescriptorPoolSize> poolSizes = {
        {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, maxSets},      // 1 per init set
        {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, maxSets * 3},  // 1 init + 2 expand
        {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, maxSets * 2}, // 1 per set
    };

    VkDescriptorPoolCreateInfo poolInfo{
        .maxSets = maxSets,
        .poolSizeCount = uint32_t(poolSizes.size()),
        .pPoolSizes = poolSizes.data(),
    };
    // ...
}
```

### Fix 2: Reuse Descriptor Sets (More Efficient)

Instead of allocating a new descriptor set per dispatch, maintain a small pool of reusable sets:

```cpp
class RmipBuilder {
    static constexpr uint32_t NUM_REUSABLE_SETS = 4;
    VkDescriptorSet m_initSet;
    VkDescriptorSet m_expandSets[NUM_REUSABLE_SETS];
    uint32_t m_currentExpandSet = 0;

    void bindExpandResources(VkCommandBuffer cmd, ...) {
        // Reuse existing set instead of allocating
        VkDescriptorSet set = m_expandSets[m_currentExpandSet];
        m_currentExpandSet = (m_currentExpandSet + 1) % NUM_REUSABLE_SETS;

        // Update descriptor set (not allocate)
        vkUpdateDescriptorSets(...);
        vkCmdBindDescriptorSets(...);
    }
};
```

This would reduce descriptor sets from 100+ per RMIP to just 5 total.

### Fix 3: Reset Pool Between RMIP Builds (Quick Workaround)

While not ideal (requires GPU sync), you could reset the pool between each RMIP:

```cpp
// In buildDisplacementRMIPs, between each material:
nvvk::endSingleTimeCommands(...);  // Wait for GPU
m_rmipBuilder.resetDescriptorPool();
nvvk::beginSingleTimeCommands(...);
```

## Resolution Summary

| Fix | Complexity | Efficiency | Recommended |
|-----|------------|------------|-------------|
| Scale pool sizes | Low | Medium | ✅ Quick fix |
| Reuse descriptor sets | Medium | High | ✅ Best long-term |
| Reset between builds | Low | Low | ⚠️ Workaround only |

## Files Involved

- [rmip_builder.cpp](../../src/rmip_builder.cpp): Lines 27-43 (pool creation), 454-502 (bindInitResources), 508-556 (bindExpandResources)
- [rmip_builder.hpp](../../src/rmip_builder.hpp): Pool and binding member variables
- [renderer.cpp](../../src/renderer.cpp): Lines 1810-1954 (buildDisplacementRMIPs)

## Test Verification

After fix, verify these scenarios work:
- [ ] 3× 512x512 displacement maps (multi_displaced_planes.gltf)
- [ ] 1× 1024x1024 displacement map
- [ ] 4× 512x512 displacement maps
- [ ] 2× 1024x1024 displacement maps
