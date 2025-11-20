/*
 * Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)
 */

#include <volk.h>
#include "convergence_analyzer.hpp"
#include <fstream>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <cstdio>  // For printf
#include <cstring> // For memcpy
#include <filesystem>

// STB image I/O (implementation already compiled in tiny_stb_implementation.cpp)
#include <stb_image_write.h>
#include <stb_image.h>

namespace matforge {

//--------------------------------------------------------------------------------------------------
// Initialization
//--------------------------------------------------------------------------------------------------
void ConvergenceAnalyzer::init(nvvk::ResourceAllocator& allocator, VkDevice device, VkExtent2D resolution)
{
  m_allocator  = &allocator;
  m_device     = device;
  m_resolution = resolution;

  // Create staging buffer for image downloads (RGBA32F)
  // Use CPU_TO_GPU for host-visible memory that can be mapped
  VkDeviceSize bufferSize = resolution.width * resolution.height * 4 * sizeof(float);
  m_allocator->createBuffer(m_stagingBuffer, bufferSize,
                            VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                            VMA_MEMORY_USAGE_CPU_TO_GPU);  // CPU-visible for readback

  // Map the staging buffer persistently
  void* mapped = nullptr;
  VkResult result = vmaMapMemory(*m_allocator, m_stagingBuffer.allocation, &mapped);
  if(result == VK_SUCCESS)
  {
    m_stagingBuffer.mapping = static_cast<uint8_t*>(mapped);
    printf("Convergence Analyzer: Staging buffer mapped successfully (%llu bytes)\n", (unsigned long long)bufferSize);
  }
  else
  {
    printf("Error: Failed to map staging buffer (VkResult: %d)\n", result);
  }
}

void ConvergenceAnalyzer::destroy()
{
  if(m_allocator && m_stagingBuffer.buffer != VK_NULL_HANDLE)
  {
    // Unmap before destroying
    if(m_stagingBuffer.mapping != nullptr)
    {
      vmaUnmapMemory(*m_allocator, m_stagingBuffer.allocation);
      m_stagingBuffer.mapping = nullptr;
    }
    m_allocator->destroyBuffer(m_stagingBuffer);
  }
  m_allocator = nullptr;
  m_device    = VK_NULL_HANDLE;
}

//--------------------------------------------------------------------------------------------------
// Reference Image Management
//--------------------------------------------------------------------------------------------------
void ConvergenceAnalyzer::captureReference(VkCommandBuffer cmd, VkImage sourceImage, VkExtent2D extent)
{
  // Record the download command (GPU copy to staging buffer)
  recordImageDownload(cmd, sourceImage, extent);
  m_resolution = extent;

  // NOTE: Caller must submit and wait for command buffer, then call finalizeReferenceCapture()
  printf("Convergence Analyzer: Reference download recorded (%ux%u) - waiting for GPU sync...\n", extent.width, extent.height);
}

void ConvergenceAnalyzer::finalizeReferenceCapture()
{
  // Read from staging buffer (after GPU copy completes)
  m_referenceImage = readStagingBuffer(m_resolution);
  m_hasReference   = true;

  printf("Convergence Analyzer: Reference image finalized (%ux%u)\n", m_resolution.width, m_resolution.height);
}

void ConvergenceAnalyzer::loadReference(const std::string& filepath)
{
  uint32_t width, height;
  m_referenceImage = loadImage(filepath, width, height);
  m_hasReference   = true;
  m_resolution     = {width, height};

  printf("Convergence Analyzer: Reference loaded from %s (%ux%u)\n", filepath.c_str(), width, height);
}

void ConvergenceAnalyzer::saveReference(const std::string& filepath)
{
  if(!m_hasReference)
  {
    printf("Error: No reference image to save\n");
    return;
  }

  saveImage(filepath, m_referenceImage, m_resolution.width, m_resolution.height);
  printf("Convergence Analyzer: Reference saved to %s\n", filepath.c_str());
}

//--------------------------------------------------------------------------------------------------
// Session Management
//--------------------------------------------------------------------------------------------------
void ConvergenceAnalyzer::startSession(const std::string& sessionName, bool useQOLDS)
{
  if(!m_hasReference)
  {
    printf("Error: Cannot start session without reference image\n");
    return;
  }

  m_sessionActive = true;
  m_sessionName   = sessionName;
  m_useQOLDS      = useQOLDS;
  m_metrics.clear();
  m_capturedFrames.clear();

  printf("Convergence Analyzer: Session started: %s (using %s)\n",
           sessionName.c_str(), useQOLDS ? "QOLDS" : "PCG");
}

void ConvergenceAnalyzer::captureFrame(VkCommandBuffer cmd, VkImage sourceImage, uint32_t sampleCount, double timeMs)
{
  if(!m_sessionActive)
  {
    printf("Error: No active session\n");
    return;
  }

  // Record the download command (GPU copy to staging buffer)
  recordImageDownload(cmd, sourceImage, m_resolution);

  // Store pending capture info
  m_pendingSampleCount = sampleCount;
  m_pendingTimeMs      = timeMs;

  // NOTE: Caller must submit and wait for command buffer, then call finalizeFrameCapture()
}

void ConvergenceAnalyzer::finalizeFrameCapture()
{
  if(!m_sessionActive)
  {
    printf("Error: No active session\n");
    return;
  }

  // Read from staging buffer (after GPU copy completes)
  std::vector<float> frameData = readStagingBuffer(m_resolution);

  // Compute metrics
  ConvergenceMetrics metrics;
  metrics.sampleCount   = m_pendingSampleCount;
  metrics.mse           = computeMSE(frameData, m_referenceImage, m_resolution.width, m_resolution.height);
  metrics.psnr          = computePSNR(metrics.mse);
  metrics.captureTimeMs = m_pendingTimeMs;
  metrics.useQOLDS      = m_useQOLDS;

  m_metrics.push_back(metrics);

  // Store frame for side-by-side comparison
  CapturedFrame frame;
  frame.sampleCount = m_pendingSampleCount;
  frame.data        = frameData;
  m_capturedFrames.push_back(frame);

  printf("Convergence Analyzer: Captured frame at %u samples (MSE: %.6f, PSNR: %.2f dB)\n",
           m_pendingSampleCount, metrics.mse, metrics.psnr);
}

void ConvergenceAnalyzer::endSession()
{
  if(!m_sessionActive)
    return;

  m_sessionActive = false;
  printf("Convergence Analyzer: Session ended: %s (%zu captures)\n",
           m_sessionName.c_str(), m_metrics.size());
}

//--------------------------------------------------------------------------------------------------
// Metrics Computation
//--------------------------------------------------------------------------------------------------
double ConvergenceAnalyzer::computeMSE(const std::vector<float>& img1, const std::vector<float>& img2,
                                       uint32_t width, uint32_t height)
{
  if(img1.size() != img2.size())
  {
    printf("Error: Image size mismatch for MSE computation\n");
    return -1.0;
  }

  double mse    = 0.0;
  size_t pixels = width * height;

  for(size_t i = 0; i < pixels; ++i)
  {
    // RGB channels only (skip alpha)
    float diffR = img1[i * 4 + 0] - img2[i * 4 + 0];
    float diffG = img1[i * 4 + 1] - img2[i * 4 + 1];
    float diffB = img1[i * 4 + 2] - img2[i * 4 + 2];

    mse += (diffR * diffR + diffG * diffG + diffB * diffB) / 3.0;
  }

  return mse / static_cast<double>(pixels);
}

double ConvergenceAnalyzer::computePSNR(double mse)
{
  if(mse <= 0.0)
    return 100.0;  // Perfect match

  // PSNR = 10 * log10(MAX^2 / MSE), where MAX = 1.0 for HDR
  return 10.0 * std::log10(1.0 / mse);
}

double ConvergenceAnalyzer::computeVariance(const std::vector<float>& accumulated,
                                            const std::vector<float>& squaredAccum,
                                            uint32_t sampleCount, uint32_t width, uint32_t height)
{
  if(sampleCount <= 1)
    return 0.0;

  double totalVariance = 0.0;
  size_t pixels        = width * height;

  for(size_t i = 0; i < pixels; ++i)
  {
    // Variance = E[X^2] - E[X]^2
    float meanR = accumulated[i * 4 + 0] / sampleCount;
    float meanG = accumulated[i * 4 + 1] / sampleCount;
    float meanB = accumulated[i * 4 + 2] / sampleCount;

    float mean2R = squaredAccum[i * 4 + 0] / sampleCount;
    float mean2G = squaredAccum[i * 4 + 1] / sampleCount;
    float mean2B = squaredAccum[i * 4 + 2] / sampleCount;

    float varR = mean2R - meanR * meanR;
    float varG = mean2G - meanG * meanG;
    float varB = mean2B - meanB * meanB;

    totalVariance += (varR + varG + varB) / 3.0;
  }

  return totalVariance / static_cast<double>(pixels);
}

//--------------------------------------------------------------------------------------------------
// Export
//--------------------------------------------------------------------------------------------------
void ConvergenceAnalyzer::exportToCSV(const std::string& filepath)
{
  std::ofstream file(filepath);
  if(!file.is_open())
  {
    printf("Error: Could not open file for writing: %s\n", filepath.c_str());
    return;
  }

  // CSV header
  file << "SampleCount,MSE,PSNR,TimeMs,Sampler\n";

  // Data rows
  for(const auto& metric : m_metrics)
  {
    file << metric.sampleCount << ","
         << metric.mse << ","
         << metric.psnr << ","
         << metric.captureTimeMs << ","
         << (metric.useQOLDS ? "QOLDS" : "PCG") << "\n";
  }

  file.close();
  printf("Convergence Analyzer: Exported to CSV: %s\n", filepath.c_str());
}

void ConvergenceAnalyzer::exportComparisonImages(const std::string& directory)
{
  // Create directory if it doesn't exist
  std::filesystem::create_directories(directory);

  for(const auto& frame : m_capturedFrames)
  {
    std::string filename = directory + "/" + m_sessionName + "_" + std::to_string(frame.sampleCount) + "spp.png";
    saveImage(filename, frame.data, m_resolution.width, m_resolution.height);
  }

  printf("Convergence Analyzer: Exported %zu comparison images to %s\n",
           m_capturedFrames.size(), directory.c_str());
}

//--------------------------------------------------------------------------------------------------
// Image I/O
//--------------------------------------------------------------------------------------------------
void ConvergenceAnalyzer::recordImageDownload(VkCommandBuffer cmd, VkImage image, VkExtent2D extent)
{
  // Resize staging buffer if resolution changed
  if(extent.width != m_resolution.width || extent.height != m_resolution.height)
  {
    printf("Convergence Analyzer: Resizing staging buffer from %ux%u to %ux%u\n",
           m_resolution.width, m_resolution.height, extent.width, extent.height);

    // Destroy old buffer
    if(m_stagingBuffer.buffer != VK_NULL_HANDLE)
    {
      if(m_stagingBuffer.mapping != nullptr)
      {
        vmaUnmapMemory(*m_allocator, m_stagingBuffer.allocation);
        m_stagingBuffer.mapping = nullptr;
      }
      m_allocator->destroyBuffer(m_stagingBuffer);
    }

    // Create new buffer with correct size
    VkDeviceSize bufferSize = extent.width * extent.height * 4 * sizeof(float);
    m_allocator->createBuffer(m_stagingBuffer, bufferSize,
                              VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                              VMA_MEMORY_USAGE_CPU_TO_GPU);

    // Map the new buffer
    void* mapped = nullptr;
    VkResult result = vmaMapMemory(*m_allocator, m_stagingBuffer.allocation, &mapped);
    if(result == VK_SUCCESS)
    {
      m_stagingBuffer.mapping = static_cast<uint8_t*>(mapped);
      printf("Convergence Analyzer: Staging buffer mapped successfully (%llu bytes)\n", (unsigned long long)bufferSize);
    }
    else
    {
      printf("Error: Failed to map staging buffer (VkResult: %d)\n", result);
    }

    m_resolution = extent;
  }

  // Transition image to TRANSFER_SRC_OPTIMAL
  VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
  barrier.srcAccessMask       = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
  barrier.dstAccessMask       = VK_ACCESS_TRANSFER_READ_BIT;
  barrier.oldLayout           = VK_IMAGE_LAYOUT_GENERAL;
  barrier.newLayout           = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
  barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  barrier.image               = image;
  barrier.subresourceRange    = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       0, 0, nullptr, 0, nullptr, 1, &barrier);

  // Copy image to staging buffer
  VkBufferImageCopy region{};
  region.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
  region.imageExtent      = {extent.width, extent.height, 1};

  vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, m_stagingBuffer.buffer, 1, &region);

  // Transition back to GENERAL
  barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
  barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
  barrier.oldLayout     = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
  barrier.newLayout     = VK_IMAGE_LAYOUT_GENERAL;

  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                       0, 0, nullptr, 0, nullptr, 1, &barrier);
}

std::vector<float> ConvergenceAnalyzer::readStagingBuffer(VkExtent2D extent)
{
  std::vector<float> data(extent.width * extent.height * 4);

  if(m_stagingBuffer.mapping != nullptr)
  {
    std::memcpy(data.data(), m_stagingBuffer.mapping, data.size() * sizeof(float));
  }
  else
  {
    printf("Warning: Staging buffer not mapped - returning empty data\n");
  }

  return data;
}

std::vector<float> ConvergenceAnalyzer::downloadImage(VkCommandBuffer cmd, VkImage image, VkExtent2D extent)
{
  // This is a convenience function that records the download command
  // NOTE: The caller MUST submit and wait for the command buffer before the data is valid!
  // For proper usage, call recordImageDownload(), submit/wait, then readStagingBuffer()
  recordImageDownload(cmd, image, extent);

  // DO NOT read here - data won't be ready yet!
  // Return empty to indicate async operation
  return std::vector<float>();
}

void ConvergenceAnalyzer::saveImage(const std::string& filepath, const std::vector<float>& data,
                                    uint32_t width, uint32_t height)
{
  if(data.empty())
  {
    printf("  Error: Cannot save empty image data\n");
    return;
  }

  // Determine format from extension
  std::filesystem::path path(filepath);
  std::string ext = path.extension().string();

  // Default to HDR if no extension
  if(ext.empty())
  {
    ext = ".hdr";
    path += ext;
  }

  bool success = false;

  if(ext == ".hdr")
  {
    // Save as HDR (preserves full float precision)
    success = stbi_write_hdr(path.string().c_str(), width, height, 4, data.data());
  }
  else if(ext == ".png" || ext == ".jpg" || ext == ".bmp")
  {
    // Convert float [0,1] to 8-bit [0,255]
    std::vector<uint8_t> data8(data.size());
    for(size_t i = 0; i < data.size(); ++i)
    {
      float val = std::clamp(data[i], 0.0f, 1.0f);
      data8[i] = static_cast<uint8_t>(val * 255.0f + 0.5f);
    }

    if(ext == ".png")
    {
      success = stbi_write_png(path.string().c_str(), width, height, 4, data8.data(), width * 4);
    }
    else if(ext == ".jpg")
    {
      success = stbi_write_jpg(path.string().c_str(), width, height, 4, data8.data(), 95);
    }
    else if(ext == ".bmp")
    {
      success = stbi_write_bmp(path.string().c_str(), width, height, 4, data8.data());
    }
  }
  else
  {
    printf("  Error: Unsupported image format '%s' (use .hdr, .png, .jpg, or .bmp)\n", ext.c_str());
    return;
  }

  if(success)
  {
    printf("  Saved image: %s (%ux%u)\n", path.string().c_str(), width, height);
  }
  else
  {
    printf("  Error: Failed to save image: %s\n", path.string().c_str());
  }
}

std::vector<float> ConvergenceAnalyzer::loadImage(const std::string& filepath, uint32_t& width, uint32_t& height)
{
  std::filesystem::path path(filepath);
  std::string ext = path.extension().string();

  // Try adding .hdr extension if no extension provided
  if(ext.empty())
  {
    path += ".hdr";
    ext = ".hdr";
  }

  // Check if file exists
  if(!std::filesystem::exists(path))
  {
    printf("Error: Image file not found: %s\n", path.string().c_str());
    return {};
  }

  std::vector<float> data;
  int w, h, channels;

  if(ext == ".hdr")
  {
    // Load HDR (native float format)
    float* pixels = stbi_loadf(path.string().c_str(), &w, &h, &channels, 4);  // Force RGBA
    if(pixels)
    {
      size_t pixelCount = static_cast<size_t>(w) * h * 4;
      data.assign(pixels, pixels + pixelCount);
      stbi_image_free(pixels);

      width = static_cast<uint32_t>(w);
      height = static_cast<uint32_t>(h);
      printf("Loaded HDR image: %s (%ux%u, %d channels)\n", path.string().c_str(), width, height, channels);
    }
    else
    {
      printf("Error: Failed to load HDR image: %s\n", path.string().c_str());
      printf("  STB Error: %s\n", stbi_failure_reason());
    }
  }
  else if(ext == ".png" || ext == ".jpg" || ext == ".bmp" || ext == ".tga")
  {
    // Load LDR image and convert to float [0,1]
    unsigned char* pixels = stbi_load(path.string().c_str(), &w, &h, &channels, 4);  // Force RGBA
    if(pixels)
    {
      size_t pixelCount = static_cast<size_t>(w) * h * 4;
      data.resize(pixelCount);

      // Convert 8-bit [0,255] to float [0,1]
      for(size_t i = 0; i < pixelCount; ++i)
      {
        data[i] = static_cast<float>(pixels[i]) / 255.0f;
      }

      stbi_image_free(pixels);

      width = static_cast<uint32_t>(w);
      height = static_cast<uint32_t>(h);
      printf("Loaded LDR image: %s (%ux%u, %d channels)\n", path.string().c_str(), width, height, channels);
    }
    else
    {
      printf("Error: Failed to load LDR image: %s\n", path.string().c_str());
      printf("  STB Error: %s\n", stbi_failure_reason());
    }
  }
  else
  {
    printf("Error: Unsupported image format '%s' (use .hdr, .png, .jpg, .bmp, or .tga)\n", ext.c_str());
  }

  return data;
}

}  // namespace matforge
