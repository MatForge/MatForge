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


#include "qolds_builder.hpp"
#include <fstream>
#include <iostream>
#include <random>
#include <cmath>
#include <cstring>

//--------------------------------------------------------------------------------------------------
// Load irreducible polynomials from initialization file
//
bool QOLDSBuilder::loadInitData(const std::string& filepath)
{
  std::ifstream file(filepath);
  if(!file.is_open())
  {
    std::cerr << "[QOLDS] Error: Could not open initialization file: " << filepath << std::endl;
    return false;
  }

  // Skip header lines (starting with 'd')
  char c = file.get();
  if(c == 'd')
  {
    file.ignore(256, '\n');
  }
  else
  {
    file.putback(c);
  }

  // Second header line
  c = file.get();
  if(c == 'd')
  {
    file.ignore(256, '\n');
  }
  else
  {
    file.putback(c);
  }

  // Read initialization data
  int32_t index = 1;  // Start from dimension 1 (dimension 0 is special)
  while(file.good() && index < QOLDS_MAX_DIMENSIONS)
  {
    int32_t d, sj, aj;
    file >> d >> sj >> aj;

    m_sobol_aj[index] = aj;
    m_sobol_sj[index] = sj;
    m_sobol_dj[index] = d;

    // Read direction numbers
    for(int i = 0; i < sj; ++i)
    {
      file >> m_sobol_mk[index][i];
    }

    index++;
  }

  std::cout << "[QOLDS] Loaded initialization data for " << (index - 1) << " dimensions" << std::endl;
  return true;
}

//--------------------------------------------------------------------------------------------------
// Build generator matrices for D dimensions using m digits
//
void QOLDSBuilder::buildMatrices(int dimensions, int digits)
{
  if(dimensions < 1 || dimensions > QOLDS_MAX_DIMENSIONS)
  {
    std::cerr << "[QOLDS] Error: Invalid number of dimensions: " << dimensions << std::endl;
    return;
  }

  if(digits < 1 || digits > QOLDS_SEQUENCE_LENGTH)
  {
    std::cerr << "[QOLDS] Error: Invalid number of digits: " << digits << std::endl;
    return;
  }

  m_dimensions = dimensions;
  m_digits     = digits;

  // Clear previous matrices
  m_matrices.clear();
  m_flattenedMatrices.clear();

  // Build matrices for each dimension
  for(int d = 1; d <= dimensions; d++)
  {
    // Generate Sobol' direction numbers
    generateMkGF3(m_sobol_aj[d], m_sobol_sj[d], m_sobol_mk[d], 3);

    // Create matrix for this dimension
    std::vector<std::vector<int32_t>> matrix(QOLDS_MATRIX_SIZE, std::vector<int32_t>(QOLDS_MATRIX_SIZE, 0));
    fillMatrix(d, matrix);

    m_matrices.push_back(matrix);

    // Flatten matrix for GPU upload (only m x m portion)
    for(int row = 0; row < digits; row++)
    {
      for(int col = 0; col < digits; col++)
      {
        m_flattenedMatrices.push_back(matrix[row][col]);
      }
    }
  }

  std::cout << "[QOLDS] Built " << dimensions << " matrices of size " << digits << "x" << digits
            << " (max " << getMaxPoints() << " points)" << std::endl;
}

//--------------------------------------------------------------------------------------------------
// Generate random scrambling seeds
//
void QOLDSBuilder::generateScrambleSeeds(uint32_t masterSeed)
{
  m_seeds.clear();

  std::random_device hwseed;
  std::default_random_engine rng(masterSeed == 0 ? hwseed() : masterSeed);

  for(int d = 0; d < m_dimensions; d++)
  {
    m_seeds.push_back(rng());
  }

  std::cout << "[QOLDS] Generated " << m_dimensions << " scrambling seeds" << std::endl;
}

//--------------------------------------------------------------------------------------------------
// Get maximum number of points
//
int QOLDSBuilder::getMaxPoints() const
{
  return static_cast<int>(std::pow(3, m_digits));
}

//--------------------------------------------------------------------------------------------------
// Convert integer to base-3 digits
//
std::vector<int32_t> QOLDSBuilder::integerDigits(int32_t val, int base, int len) const
{
  std::vector<int32_t> digits;
  for(int i = 0; i < len; i++)
  {
    digits.push_back(val % base);
    val = val / base;
  }
  return digits;
}

//--------------------------------------------------------------------------------------------------
// Convert base-3 digits back to integer
//
int32_t QOLDSBuilder::fromDigits(const std::vector<int32_t>& digits, int base, int len) const
{
  int32_t pow = 1, res = 0;
  for(int i = 0; i < len; i++)
  {
    res += pow * digits[i];
    pow = pow * base;
  }
  return res;
}

//--------------------------------------------------------------------------------------------------
// Multiply by factor in GF(N)
//
int32_t QOLDSBuilder::multiplyByFactorInGFN(int32_t x, int32_t factor, int base, int len) const
{
  std::vector<int32_t> digits = integerDigits(x, base, len);
  for(int i = 0; i < len; i++)
  {
    digits[i] = (digits[i] * factor) % base;
  }
  return fromDigits(digits, base, len);
}

//--------------------------------------------------------------------------------------------------
// XOR operation in GF(N)
//
int32_t QOLDSBuilder::bitXorGFN(int base, const std::vector<int32_t>& lst, int len, int polynomialDegree) const
{
  int32_t digits[QOLDS_SEQUENCE_LENGTH][QOLDS_SEQUENCE_LENGTH];

  // Initialize to zero
  for(int i = 0; i < QOLDS_SEQUENCE_LENGTH; i++)
  {
    for(int j = 0; j < QOLDS_SEQUENCE_LENGTH; j++)
    {
      digits[i][j] = 0;
    }
  }

  // Convert list elements to digits
  for(int i = 0; i <= polynomialDegree; i++)
  {
    std::vector<int32_t> d = integerDigits(lst[i], base, len);
    for(int j = 0; j < len; j++)
    {
      digits[i][j] = d[j];
    }
  }

  // XOR digits
  std::vector<int32_t> finalDigits(QOLDS_SEQUENCE_LENGTH + 1, 0);
  for(int i = 0; i < len; i++)
  {
    finalDigits[i] = 0;
    for(int j = 0; j <= polynomialDegree; j++)
    {
      finalDigits[i] += digits[j][i];
    }
    finalDigits[i] = finalDigits[i] % base;
  }

  return fromDigits(finalDigits, base, len);
}

//--------------------------------------------------------------------------------------------------
// Generate direction numbers using irreducible polynomial
//
void QOLDSBuilder::generateMkGF3(int32_t ipolynomial, int32_t polynomialDegree, int32_t* msobol, int base)
{
  std::vector<int32_t> polynomial = integerDigits(ipolynomial, base, polynomialDegree + 1);

  for(int i = polynomialDegree + 1; i <= QOLDS_SEQUENCE_LENGTH; i++)
  {
    std::vector<int32_t> lst;
    lst.push_back(msobol[i - polynomialDegree - 1]);

    for(int j = 1; j < polynomialDegree + 1; j++)
    {
      lst.push_back(pow3Tab[j] * multiplyByFactorInGFN(msobol[i - j - 1],
                                                        convertToGF3[polynomial[polynomialDegree - j]],
                                                        base,
                                                        QOLDS_SEQUENCE_LENGTH));
    }

    msobol[i - 1] = bitXorGFN(base, lst, i, polynomialDegree);
  }
}

//--------------------------------------------------------------------------------------------------
// Fill matrix from sobol_mk data
//
void QOLDSBuilder::fillMatrix(int sobolMkIndex, std::vector<std::vector<int32_t>>& matrix)
{
  for(int i = 0; i < QOLDS_MATRIX_SIZE; i++)
  {
    int32_t val = m_sobol_mk[sobolMkIndex][i];
    int     len = i + 1;

    std::vector<int32_t> digits = integerDigits(val, 3, len);
    for(int j = 0; j < len; j++)
    {
      matrix[len - j - 1][i] = digits[j];
    }
  }
}
