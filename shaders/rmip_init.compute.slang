#include "rmip_common.h.slang"

// Initialize base level from displacement map
[[vk::binding(0, 0)]]
Texture2D<float> displacementMap;

[[vk::binding(1, 0)]]
RWTexture2DArray<float2> rmipOutput;  // float2 = (min, max)

[[vk::binding(2, 0)]]
ConstantBuffer<RMIPBuildParams> params;

[shader("compute")]
[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 pos = dispatchThreadID.xy;
    
    if (any(pos >= params.inputResolution))
        return;
    
    // Read displacement value
    float displacement = displacementMap[pos];
    
    // Write to layer (0,0) - single texel queries
    uint layerIndex = computeLayerIndex(0, 0, params.maxLevel + 1);
    rmipOutput[uint3(pos, layerIndex)] = float2(displacement, displacement);
}