#include "rmip_common.h.slang"

// V38 FIX: Both input and output must be RWTexture2DArray for [] operator access
// Binding 0 is now VK_DESCRIPTOR_TYPE_STORAGE_IMAGE (not SAMPLED_IMAGE)
// This is required because Vulkan SAMPLED_IMAGE doesn't support [] operator (Load)
[[vk::binding(0, 0)]]
RWTexture2DArray<float2> rmipInput;  // Read-only access via STORAGE_IMAGE

[[vk::binding(1, 0)]]
RWTexture2DArray<float2> rmipOutput;

// V38c FIX: Use push constants instead of uniform buffer
// The uniform buffer was being overwritten by subsequent dispatches before GPU execution
// Push constants are recorded per-dispatch and don't have this race condition
[[vk::push_constant]]
RMIPBuildParams params;

[shader("compute")]
[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pos = dispatchThreadID.xy;
    uint p = params.currentP;
    uint q = params.currentQ;

    // Early exit for base level (handled by init shader)
    if (p == 0 && q == 0)
        return;

    uint width = 1u << p;
    uint height = 1u << q;

    // Check if position is valid for this rectangle size
    uint2 maxPos = params.inputResolution - uint2(width, height) + uint2(1, 1);
    if (any(pos >= maxPos))
        return;

    uint stride = params.maxLevel + 1;

    MinMax result;

    // Branch based on expansion type
    if (p == 0 && q > 0)
    {
        // VERTICAL EXPANSION: Double height only
        uint prevQ = q - 1;
        uint halfHeight = 1u << prevQ;
        uint inputLayer = computeLayerIndex(0, prevQ, stride);

        float2 topData = rmipInput[uint3(pos, inputLayer)];
        float2 bottomData = rmipInput[uint3(pos + uint2(0, halfHeight), inputLayer)];

        MinMax top = { topData.x, topData.y };
        MinMax bottom = { bottomData.x, bottomData.y };
        result = combineMinMax(top, bottom);
    }
    else if (p > 0 && q == 0)
    {
        // HORIZONTAL EXPANSION: Double width only
        uint prevP = p - 1;
        uint halfWidth = 1u << prevP;
        uint inputLayer = computeLayerIndex(prevP, 0, stride);

        float2 leftData = rmipInput[uint3(pos, inputLayer)];
        float2 rightData = rmipInput[uint3(pos + uint2(halfWidth, 0), inputLayer)];

        MinMax left = { leftData.x, leftData.y };
        MinMax right = { rightData.x, rightData.y };
        result = combineMinMax(left, right);
    }
    else // p > 0 && q > 0
    {
        // ============================================
        // 2D EXPANSION: Double both width and height
        // Reads 4 rectangles in a 2x2 grid
        // ============================================
        uint prevP = p - 1;
        uint prevQ = q - 1;
        uint halfWidth = 1u << prevP;
        uint halfHeight = 1u << prevQ;
        uint inputLayer = computeLayerIndex(prevP, prevQ, stride);
        
        // Read 4 sub-rectangles
        float2 tlData = rmipInput[uint3(pos, inputLayer)];
        float2 trData = rmipInput[uint3(pos + uint2(halfWidth, 0), inputLayer)];
        float2 blData = rmipInput[uint3(pos + uint2(0, halfHeight), inputLayer)];
        float2 brData = rmipInput[uint3(pos + uint2(halfWidth, halfHeight), inputLayer)];
        
        MinMax tl = { tlData.x, tlData.y };
        MinMax tr = { trData.x, trData.y };
        MinMax bl = { blData.x, blData.y };
        MinMax br = { brData.x, brData.y };
        
        result = combineMinMax4(tl, tr, bl, br);
    }
    
    // Write result to output layer
    uint outputLayer = computeLayerIndex(p, q, stride);
    rmipOutput[uint3(pos, outputLayer)] = float2(result.minValue, result.maxValue);
}