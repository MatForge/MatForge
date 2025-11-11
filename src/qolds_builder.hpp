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


#pragma once

#include <vector>
#include <string>
#include <cstdint>

//--------------------------------------------------------------------------------------------------
// Constants
//
constexpr int QOLDS_MAX_DIMENSIONS = 48;    // Maximum supported dimensions
constexpr int QOLDS_SEQUENCE_LENGTH = 10;  // 3^10 = 59049 max points
constexpr int QOLDS_MATRIX_SIZE = 20;      // Matrix size for generation

//--------------------------------------------------------------------------------------------------
// QOLDSBuilder: Host-side generator for QOLDS sampling matrices
//
// This class builds the Sobol' generator matrices in GF(3) that will be used
// by the GPU for generating Quad-Optimized Low-Discrepancy Sequences.
//
class QOLDSBuilder
{
public:
  QOLDSBuilder() = default;
  ~QOLDSBuilder() = default;

  // Load irreducible polynomials from initialization file
  // Returns true on success, false on failure
  bool loadInitData(const std::string& filepath);

  // Build generator matrices for D dimensions using m digits (3^m points)
  // D: number of dimensions (1-48)
  // m: number of base-3 digits (1-10, produces 3^m points)
  void buildMatrices(int dimensions, int digits);

  // Generate random scrambling seeds for Owen scrambling
  // masterSeed: seed for random number generator (0 = use random device)
  void generateScrambleSeeds(uint32_t masterSeed = 0);

  // Get the flattened matrix data for GPU upload
  // Returns: matrices in row-major order [D][m][m]
  const std::vector<int32_t>& getMatrixData() const { return m_flattenedMatrices; }

  // Get scrambling seeds (one per dimension)
  const std::vector<uint32_t>& getScrambleSeeds() const { return m_seeds; }

  // Get the number of dimensions
  int getDimensions() const { return m_dimensions; }

  // Get the number of digits (m, where 3^m = max points)
  int getDigits() const { return m_digits; }

  // Get maximum number of points (3^m)
  int getMaxPoints() const;

private:
  //--------------------------------------------------------------------------------------------------
  // Base-3 arithmetic utilities
  //
  // Convert integer to base-3 digits
  std::vector<int32_t> integerDigits(int32_t val, int base, int len) const;

  // Convert base-3 digits back to integer
  int32_t fromDigits(const std::vector<int32_t>& digits, int base, int len) const;

  // Multiply by factor in GF(N)
  int32_t multiplyByFactorInGFN(int32_t x, int32_t factor, int base, int len) const;

  // XOR operation in GF(N)
  int32_t bitXorGFN(int base, const std::vector<int32_t>& lst, int len, int polynomialDegree) const;

  //--------------------------------------------------------------------------------------------------
  // Sobol' matrix generation
  //
  // Generate direction numbers using irreducible polynomial
  void generateMkGF3(int32_t ipolynomial, int32_t polynomialDegree, int32_t* msobol, int base);

  // Fill matrix from sobol_mk data
  void fillMatrix(int sobolMkIndex, std::vector<std::vector<int32_t>>& matrix);

  //--------------------------------------------------------------------------------------------------
  // Member variables
  //
  int m_dimensions{0};  // Number of dimensions
  int m_digits{0};      // Number of base-3 digits (m)

  // Sobol' initialization data (loaded from .dat file)
  int32_t m_sobol_dj[QOLDS_MAX_DIMENSIONS];        // Polynomial degrees
  int32_t m_sobol_sj[QOLDS_MAX_DIMENSIONS];        // Number of direction numbers
  int32_t m_sobol_aj[QOLDS_MAX_DIMENSIONS];        // Irreducible polynomial coefficients
  int32_t m_sobol_mk[QOLDS_MAX_DIMENSIONS][32];    // Direction numbers

  // Generated matrices (one per dimension)
  std::vector<std::vector<std::vector<int32_t>>> m_matrices;  // [D][m][m]
  std::vector<int32_t>                           m_flattenedMatrices;  // Flattened for GPU upload

  // Owen scrambling seeds (one per dimension)
  std::vector<uint32_t> m_seeds;

  // Power of 3 lookup table
  static constexpr uint32_t pow3Tab[21] = {1, 3, 9, 27, 81, 243, 729, 2187, 6561, 19683, 59049,
    177147, 531441, 1594323, 4782969, 14348907, 43046721, 129140163, 387420489, 1162261467, 3486784401};

  // Conversion table for GF(3)
  static constexpr int32_t convertToGF3[3] = {0, 2, 1};
};
