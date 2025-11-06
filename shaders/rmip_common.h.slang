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