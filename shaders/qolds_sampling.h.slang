/*
 * Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-FileCopyrightText: Copyright (c) 2025, MatForge Team
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef QOLDS_SAMPLING_H_SLANG
#define QOLDS_SAMPLING_H_SLANG

//--------------------------------------------------------------------------------------------------
// Constants
//
static const uint QOLDS_MAX_DIGITS = 10;  // Maximum base-3 digits (3^10 = 59,049 points)

// Power-of-3 lookup table for fast computation
static const uint pow3Tab[11] = {
    1, 3, 9, 27, 81, 243, 729, 2187, 6561, 19683, 59049
};

//--------------------------------------------------------------------------------------------------
// Integer3: Base-3 integer representation
//
// Stores an integer as an array of base-3 digits for efficient Sobol' point generation.
// Digits are stored in little-endian order: digits[0] is the least significant.
//
struct Integer3
{
    int digits[QOLDS_MAX_DIGITS];  // Base-3 digits (each 0, 1, or 2)

    //----------------------------------------------------------------------------------------------
    // Constructors
    //

    // Default constructor (zero)
    __init()
    {
        for (uint i = 0; i < QOLDS_MAX_DIGITS; i++)
            digits[i] = 0;
    }

    // Construct from unsigned integer
    __init(uint x)
    {
        for (uint i = 0; i < QOLDS_MAX_DIGITS; i++)
        {
            digits[i] = int(x % 3u);
            x = x / 3u;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Conversion functions
    //

    // Convert to unsigned integer (up to m digits)
    uint value(uint m)
    {
        uint x = 0;
        for (uint i = 0; i < m; i++)
            x += pow3Tab[i] * uint(digits[i]);
        return x;
    }

    // Convert to double in [0, 1) (up to m digits)
    float toDouble(uint m)
    {
        return float(value(m)) / float(pow3Tab[m]);
    }

    //----------------------------------------------------------------------------------------------
    // Base-3 arithmetic operations (static utility functions)
    //

    // Fast modulo 3 using lookup table
    static int mod(int x)
    {
        static const int mod3Table[6] = {0, 1, 2, 0, 1, 2};
        return mod3Table[x];
    }

    // Fused multiply-add in GF(3): (a + b*c) % 3
    // This is the core operation for point generation
    static int fma(int a, int b, int c)
    {
        // Precomputed lookup table for (a + b*c) % 3
        // Index: a*16 + b*4 + c (a,b,c in [0,2])
        static const int fma3Table[64] = {
            0, 0, 0, 0,  0, 1, 2, 0,  0, 2, 1, 0,  0, 0, 0, 0,
            1, 1, 1, 0,  1, 2, 0, 0,  1, 0, 2, 0,  0, 0, 0, 0,
            2, 2, 2, 0,  2, 0, 1, 0,  2, 1, 0, 0,  0, 0, 0, 0,
            0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0
        };
        return fma3Table[a * 16 + b * 4 + c];
    }
};

//--------------------------------------------------------------------------------------------------
// Gray Code Generation
//
// Generates the base-3 Gray code of an integer.
// Gray codes ensure that consecutive numbers differ by only one digit,
// which is crucial for incremental Sobol' point generation.
//
// Reference: https://en.wikipedia.org/wiki/Gray_code#n-ary_Gray_code
//
Integer3 graycode(Integer3 n)
{
    Integer3 gray;

    int shift = 0;
    for (int i = int(QOLDS_MAX_DIGITS) - 1; i >= 0; i--)
    {
        // The Gray digit gets shifted down by the sum of the higher digits
        gray.digits[i] = Integer3.mod(n.digits[i] + shift);
        shift = Integer3.mod(shift + 3 - gray.digits[i]);
    }

    return gray;
}

//--------------------------------------------------------------------------------------------------
// Sobol' Point Generation (Incremental)
//
// Generates a Sobol' point by incrementally modifying the previous point.
// This is more efficient than generating from scratch.
//
// Parameters:
//   matrix: Generator matrix for this dimension (m x m)
//   m:      Number of base-3 digits
//   i3:     Current index (base-3)
//   p3:     Previous index (base-3) [input/output]
//   x3:     Previous point (base-3) [input/output]
//
// Returns: Updated point x3
//
Integer3 point3_digits(StructuredBuffer<int> matrix, uint matrixOffset, uint m,
                       Integer3 i3, inout Integer3 p3, inout Integer3 x3)
{
    for (uint k = 0; k < m; k++)
    {
        // Find modified digits: previous index (i-1) and index (i)
        if (p3.digits[k] != i3.digits[k])
        {
            int d = int(i3.digits[k]) - int(p3.digits[k]);
            d = Integer3.mod(d + 3);

            // Update previous point: x3 += d * matrix column k
            for (uint j = 0; j < m; j++)
            {
                // Access matrix[m-1-j][k]
                int matrixValue = matrix[matrixOffset + (m - 1 - j) * m + k];
                x3.digits[j] = Integer3.fma(x3.digits[j], d, matrixValue);
            }
        }
    }

    // Update previous index
    p3 = i3;
    return x3;
}

//--------------------------------------------------------------------------------------------------
// Counter-Based RNG (FCRNG)
//
// Fast counter-based random number generator for Owen scrambling.
// All small crush tests pass (as verified in reference implementation).
//
struct FCRNG
{
    uint n;    // Counter
    uint key;  // Scrambling key

    // Initialize with seed
    __init(uint seed)
    {
        n = 0;
        key = (seed << 1u) | 1u;
    }

    // Set counter to specific index (for tree traversal)
    FCRNG index(uint i)
    {
        FCRNG result;
        result.n = i;
        result.key = key;
        return result;
    }

    // Hash function
    uint hash(uint x)
    {
        x ^= x >> 16u;
        x *= 0x21f0aaadu;
        x ^= x >> 15u;
        x *= 0xd35a2d97u;
        x ^= x >> 15u;
        return x;
    }

    // Generate next random number
    [mutating]
    uint sample()
    {
        n++;
        return hash(n * key);
    }

    // Generate random number in range [0, range)
    [mutating]
    uint sampleRange(uint range)
    {
        // Efficiently generating a number in a range
        // cf http://www.pcg-random.org/posts/bounded-rands.html
        uint divisor = ((0u - range) / range) + 1u;  // (2^32) / range
        if (divisor == 0u) return 0u;

        // Rejection sampling (usually succeeds on first try)
        for (int attempt = 0; attempt < 10; attempt++)  // Safety limit
        {
            uint x = sample() / divisor;
            if (x < range) return x;
        }
        return 0u;  // Fallback
    }
};

//--------------------------------------------------------------------------------------------------
// Owen Scrambling (Nested Uniform Scrambling)
//
// Applies Owen scrambling to a base-3 integer for better randomization.
// Uses a permutation tree where each node has a random permutation of {0, 1, 2}.
//
// Parameters:
//   a3:      Input integer (base-3)
//   seed:    Random seed for permutation generation
//   ndigits: Number of digits to scramble
//
// Returns: Scrambled integer (base-3)
//
Integer3 scramble_base3(Integer3 a3, uint seed, uint ndigits)
{
    // All 6 permutations of {0, 1, 2}
    static const int scrambleTable[6][3] = {
        {0, 1, 2},
        {0, 2, 1},
        {1, 0, 2},
        {1, 2, 0},
        {2, 0, 1},
        {2, 1, 0}
    };

    // Counter-based random number generator
    FCRNG rng = FCRNG(seed);

    Integer3 b3;
    uint nodeIndex = 0;  // Start at the root node

    for (uint i = 0; i < ndigits; i++)
    {
        // Get a random permutation using the node index
        FCRNG tempRng = rng.index(nodeIndex);
        uint flip = tempRng.sampleRange(6u);

        // Get digit (process most significant first)
        uint digit = uint(a3.digits[ndigits - 1 - i]);

        // Store the permuted digit
        b3.digits[ndigits - 1 - i] = scrambleTable[flip][digit];

        // Continue walking the permutation tree
        // Heap layout: root i=0, children 3*i+1, 3*i+2, 3*i+3
        nodeIndex = 3u * nodeIndex + 1u + digit;
    }

    return b3;
}

//--------------------------------------------------------------------------------------------------
// QOLDS Sampling - Main API
//
// Generates a QOLDS sample for a given index and dimension.
// This is the main function called by the path tracer.
//
// Parameters:
//   index:      Sample index (which point in the sequence)
//   dimension:  Dimension index (which component to sample)
//   matrices:   Generator matrices buffer [D x m x m]
//   seeds:      Owen scrambling seeds [D]
//   m:          Number of base-3 digits (default 5 → 3^5 = 243 points)
//
// Returns: Float in [0, 1)
//
// Note: For efficiency, we don't cache state across calls. If performance is critical,
//       consider caching p3 and x3 per dimension in the calling code.
//
float qolds_sample(uint index, uint dimension,
                   StructuredBuffer<int> matrices,
                   StructuredBuffer<uint> seeds,
                   uint m = 5)
{
    // Get offset for this dimension's matrix
    uint matrixOffset = dimension * m * m;

    // Convert index to base-3
    Integer3 i3 = Integer3(index);

    // Generate Sobol' point (starting from zero)
    Integer3 p3;  // Previous index (initialized to zero)
    Integer3 x3;  // Previous point (initialized to zero)

    // Incremental generation
    x3 = point3_digits(matrices, matrixOffset, m, i3, p3, x3);

    // Apply Owen scrambling
    uint seed = seeds[dimension];
    Integer3 scrambled = scramble_base3(x3, seed, m);

    // Convert to float in [0, 1)
    return scrambled.toDouble(m);
}

//--------------------------------------------------------------------------------------------------
// Alternative API: Pre-computed Gray Code (for Gray code traversal)
//
// If you want to traverse samples in Gray code order (consecutive indices differ by one digit),
// use this version. Currently not used, but kept for future optimization.
//
float qolds_sample_graycode(uint index, uint dimension,
                            StructuredBuffer<int> matrices,
                            StructuredBuffer<uint> seeds,
                            uint m = 5)
{
    uint matrixOffset = dimension * m * m;

    // Convert index to Gray code
    Integer3 i3 = Integer3(index);
    Integer3 ig3 = graycode(i3);

    // Generate point in Gray code order
    Integer3 pg3;
    Integer3 x3;
    x3 = point3_digits(matrices, matrixOffset, m, ig3, pg3, x3);

    // Scramble and convert
    uint seed = seeds[dimension];
    Integer3 scrambled = scramble_base3(x3, seed, m);
    return scrambled.toDouble(m);
}

//--------------------------------------------------------------------------------------------------
// Optimized API with State Caching
//
// For advanced usage: if you're generating many samples for the same dimension,
// you can cache the previous state (p3, x3) to avoid recomputation.
//
struct QOLDSState
{
    Integer3 p3;  // Previous index
    Integer3 x3;  // Previous point
};

// Initialize state for a dimension
QOLDSState qolds_init_state()
{
    QOLDSState state;
    // p3 and x3 default to zero (Integer3 default constructor)
    return state;
}

// Sample with state caching (more efficient for sequential access)
float qolds_sample_cached(uint index, uint dimension,
                          StructuredBuffer<int> matrices,
                          StructuredBuffer<uint> seeds,
                          inout QOLDSState state,
                          uint m = 5)
{
    uint matrixOffset = dimension * m * m;
    Integer3 i3 = Integer3(index);

    // Incremental generation using cached state
    state.x3 = point3_digits(matrices, matrixOffset, m, i3, state.p3, state.x3);

    // Scramble and convert
    uint seed = seeds[dimension];
    Integer3 scrambled = scramble_base3(state.x3, seed, m);
    return scrambled.toDouble(m);
}

#endif  // QOLDS_SAMPLING_H_SLANG
