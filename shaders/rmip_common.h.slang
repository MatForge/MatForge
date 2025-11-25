//==============================================================================
// rmip_common.h.slang
// RMIP common structures and utilities
//=============================================================================

//------------------------------------------------------------------------------
// Structures
//------------------------------------------------------------------------------

struct RMIPBuildParams
{
    uint2 inputResolution;      // N x N (power of 2)
    uint maxLevel;              // log2(N)
    uint currentP;              // Current p dimension being built
    uint currentQ;              // Current q dimension being built
};

struct MinMax
{
    float minValue;
    float maxValue;
};

//------------------------------------------------------------------------------
// Helper Functions
//------------------------------------------------------------------------------

/// Compute RMIP layer index from p, q coordinates
uint computeLayerIndex(uint p, uint q, uint stride)
{
    return p + q * stride;
}

/// Combine two MinMax pairs
MinMax combineMinMax(MinMax a, MinMax b)
{
    MinMax result;
    result.minValue = min(a.minValue, b.minValue);
    result.maxValue = max(a.maxValue, b.maxValue);
    return result;
}

/// Combine four MinMax pairs (top-left, top-right, bottom-left, bottom-right)
MinMax combineMinMax4(MinMax tl, MinMax tr, MinMax bl, MinMax br)
{
    MinMax temp1 = combineMinMax(tl, tr);
    MinMax temp2 = combineMinMax(bl, br);
    return combineMinMax(temp1, temp2);
}

uint getRmipLayer(uint p, uint q, uint maxLevel)
{
    return p * (maxLevel + 1) + q;
}

//-----------------------------------------------------------------------
// Decompose rectangle query into 4 overlapping power-of-2 rectangles
// Based on Amir et al. 2007
//-----------------------------------------------------------------------
struct RmipQuery
{
    uint p, q;           // Size parameters: width = 2^p, height = 2^q
    float2 positions[4]; // The 4 query positions in texel space
};

RmipQuery decomposeQuery(float2 minPos, float2 maxPos)
{
    RmipQuery query;

    float2 size = maxPos - minPos;

    // Find the largest power-of-2 that fits in each dimension
    query.p = uint(floor(log2(max(1.0, size.x))));
    query.q = uint(floor(log2(max(1.0, size.y))));

    float width = float(1u << query.p);
    float height = float(1u << query.q);

    // Four overlapping rectangles
    query.positions[0] = minPos;                              // Top-left
    query.positions[1] = float2(maxPos.x - width, minPos.y);  // Top-right
    query.positions[2] = float2(minPos.x, maxPos.y - height); // Bottom-left
    query.positions[3] = maxPos - float2(width, height);      // Bottom-right

    return query;
}

//-----------------------------------------------------------------------
// Sample RMIP at specific position and layer
//-----------------------------------------------------------------------
float2 sampleRMIP(Texture2DArray<float2> rmipTex, SamplerState samp, 
                  float2 position, uint layer, uint2 texSize)
{
    // Convert position to UV coordinates
    float2 uv = (position + 0.5) / float2(texSize); // Add 0.5 for pixel center
    uv = clamp(uv, 0.0, 1.0);

    // Sample the RMIP texture
    return rmipTex.SampleLevel(samp, float3(uv, float(layer)), 0).xy;
}

//-----------------------------------------------------------------------
// Full RMIP query with 4-rectangle decomposition
//-----------------------------------------------------------------------
float2 queryRMIPFull(Texture2DArray<float2> rmipTex, SamplerState samp,
                     float2 uvMin, float2 uvMax, uint maxLevel)
{
    uint2 texSize;
    uint arraySize;
    uint numberOfLevels;
    rmipTex.GetDimensions(0, texSize.x, texSize.y, arraySize, numberOfLevels);

    // Convert UV to texel coordinates
    float2 minPos = uvMin * float2(texSize);
    float2 maxPos = uvMax * float2(texSize);

    // Decompose query
    RmipQuery query = decomposeQuery(minPos, maxPos);

    // Clamp to valid levels
    query.p = min(query.p, maxLevel);
    query.q = min(query.q, maxLevel);

    // Get layer index
    uint layer = getRmipLayer(query.p, query.q, maxLevel);

    // Sample all 4 positions and combine
    float2 bounds = float2(1e30, -1e30);
    for (int i = 0; i < 4; i++)
    {
        float2 sampledBounds = sampleRMIP(rmipTex, samp, query.positions[i], layer, texSize);
        bounds.x = min(bounds.x, sampledBounds.x);
        bounds.y = max(bounds.y, sampledBounds.y);
    }

    return bounds;
}
