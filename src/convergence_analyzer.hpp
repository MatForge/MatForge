/*
 * Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)
 *
 * Convergence Analyzer for QOLDS vs PCG comparison
 * Measures variance reduction and convergence speed
 */

#pragma once

#include <vector>
#include <string>
#include <vulkan/vulkan_core.h>
#include <nvvk/resource_allocator.hpp>

namespace matforge {

//--------------------------------------------------------------------------------------------------
// Convergence Metrics
//--------------------------------------------------------------------------------------------------
struct ConvergenceMetrics
{
  uint32_t sampleCount{0};        // Total samples per pixel at this capture
  double   mse{0.0};              // Mean Squared Error vs reference
  double   psnr{0.0};             // Peak Signal-to-Noise Ratio
  double   variance{0.0};         // Per-pixel variance
  double   captureTimeMs{0.0};    // Time taken to reach this sample count
  bool     useQOLDS{false};       // Which sampler was used
};

//--------------------------------------------------------------------------------------------------
// Convergence Analyzer
//
// Captures frames at regular sample intervals and computes convergence metrics
// Usage:
//   1. Set reference image (high sample count ground truth)
//   2. Start capture session
//   3. Capture frames at sample counts: 1, 2, 4, 8, 16, 32, 64, ...
//   4. Export convergence data to CSV
//   5. Generate plots with Python
//--------------------------------------------------------------------------------------------------
class ConvergenceAnalyzer
{
public:
  ConvergenceAnalyzer() = default;
  ~ConvergenceAnalyzer() { destroy(); }

  // Initialize analyzer
  void init(nvvk::ResourceAllocator& allocator, VkDevice device, VkExtent2D resolution);
  void destroy();

  //----------------------------------------------------------------------------------------------
  // Reference Image Management
  //----------------------------------------------------------------------------------------------

  // Set reference image (ground truth) from current frame
  void captureReference(VkCommandBuffer cmd, VkImage sourceImage, VkExtent2D extent);

  // Finalize reference capture (call after command buffer completes)
  void finalizeReferenceCapture();

  // Load reference from file (high-quality render)
  void loadReference(const std::string& filepath);

  // Save reference to file
  void saveReference(const std::string& filepath);

  //----------------------------------------------------------------------------------------------
  // Convergence Capture
  //----------------------------------------------------------------------------------------------

  // Start new capture session
  void startSession(const std::string& sessionName, bool useQOLDS);

  // Capture current frame at given sample count
  void captureFrame(VkCommandBuffer cmd, VkImage sourceImage, uint32_t sampleCount, double timeMs);

  // Finalize frame capture (call after command buffer completes)
  void finalizeFrameCapture();

  // End session and export results
  void endSession();

  //----------------------------------------------------------------------------------------------
  // Metrics Computation
  //----------------------------------------------------------------------------------------------

  // Compute MSE between two images
  static double computeMSE(const std::vector<float>& img1, const std::vector<float>& img2, uint32_t width, uint32_t height);

  // Compute PSNR from MSE
  static double computePSNR(double mse);

  // Compute per-pixel variance from accumulated samples
  static double computeVariance(const std::vector<float>& accumulated, const std::vector<float>& squaredAccum,
                                uint32_t sampleCount, uint32_t width, uint32_t height);

  //----------------------------------------------------------------------------------------------
  // Export & Analysis
  //----------------------------------------------------------------------------------------------

  // Export convergence data to CSV
  void exportToCSV(const std::string& filepath);

  // Export side-by-side comparison images
  void exportComparisonImages(const std::string& directory);

  // Get metrics for display in GUI
  const std::vector<ConvergenceMetrics>& getMetrics() const { return m_metrics; }

  // Get current session status
  bool isSessionActive() const { return m_sessionActive; }
  std::string getSessionName() const { return m_sessionName; }

private:
  // Record image download command (GPU -> staging buffer)
  void recordImageDownload(VkCommandBuffer cmd, VkImage image, VkExtent2D extent);

  // Read from staging buffer (call after GPU copy completes)
  std::vector<float> readStagingBuffer(VkExtent2D extent);

  // Download image from GPU to CPU (convenience function - handles sync internally)
  std::vector<float> downloadImage(VkCommandBuffer cmd, VkImage image, VkExtent2D extent);

  // Save image to file (PNG or EXR)
  void saveImage(const std::string& filepath, const std::vector<float>& data, uint32_t width, uint32_t height);

  // Load image from file
  std::vector<float> loadImage(const std::string& filepath, uint32_t& width, uint32_t& height);

private:
  nvvk::ResourceAllocator* m_allocator{nullptr};
  VkDevice                 m_device{VK_NULL_HANDLE};
  VkExtent2D               m_resolution{};

  // Reference image (ground truth)
  std::vector<float> m_referenceImage;
  bool               m_hasReference{false};

  // Current session
  bool        m_sessionActive{false};
  std::string m_sessionName;
  bool        m_useQOLDS{false};

  // Pending capture (for async download)
  uint32_t m_pendingSampleCount{0};
  double   m_pendingTimeMs{0.0};

  // Captured metrics
  std::vector<ConvergenceMetrics> m_metrics;

  // Captured frames (for side-by-side comparison)
  struct CapturedFrame
  {
    uint32_t           sampleCount;
    std::vector<float> data;
  };
  std::vector<CapturedFrame> m_capturedFrames;

  // Staging buffer for image download
  nvvk::Buffer m_stagingBuffer;
};

}  // namespace matforge
