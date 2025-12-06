/*
 * Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)
 *
 * VNDF Analyzer for Bounded VNDF vs Standard VNDF comparison
 * Tracks rejection rates, variance reduction, and performance metrics
 */

#pragma once

#include <vector>
#include <string>
#include <chrono>
#include <vulkan/vulkan_core.h>
#include <nvvk/resource_allocator.hpp>

namespace matforge {

    //--------------------------------------------------------------------------------------------------
    // VNDF Analysis Metrics
    //--------------------------------------------------------------------------------------------------
    struct VNDFMetrics
    {
        uint32_t sampleCount{ 0 };           // Samples per pixel at this capture
        float    roughnessAlpha{ 0.0f };     // Roughness value (α) being tested
        float    roughnessAlphaX{ 0.0f };    // Anisotropic roughness X (αₓ)
        float    roughnessAlphaY{ 0.0f };    // Anisotropic roughness Y (αᵧ)
        bool     isAnisotropic{ false };     // Whether testing anisotropic material

        // Rejection rate metrics
        uint64_t totalSamples{ 0 };          // Total VNDF samples generated
        uint64_t rejectedSamples{ 0 };       // Samples rejected (in lower hemisphere)
        float    rejectionRate{ 0.0f };      // Percentage of rejected samples

        // Quality metrics (vs reference)
        double   mse{ 0.0 };                 // Mean Squared Error
        double   rmse{ 0.0 };                // Root Mean Squared Error  
        double   psnr{ 0.0 };                // Peak Signal-to-Noise Ratio

        // Performance metrics
        double   renderTimeMs{ 0.0 };        // Frame render time
        double   samplingOverheadMs{ 0.0 };  // Additional time from bounded sampling
        double   qualityPerTime{ 0.0 };      // 1/RMSE × 1/time metric

        bool     useBoundedVNDF{ false };    // Which method was used
        double   captureTimeMs{ 0.0 };       // Total elapsed time
    };

    //--------------------------------------------------------------------------------------------------
    // Test Configuration for VNDF Analysis
    //--------------------------------------------------------------------------------------------------
    struct VNDFTestConfig
    {
        // Roughness test matrix
        std::vector<float> roughnessValues = { 0.2f, 0.4f, 0.6f, 0.8f, 1.0f };

        // Anisotropic test configurations (fixed αₓ, varying αᵧ)
        struct AnisotropicConfig {
            float fixedAlphaX;
            std::vector<float> alphaYValues;
        };
        std::vector<AnisotropicConfig> anisotropicTests = {
          {1.0f, {0.3f, 0.5f, 0.7f, 0.9f}},  // Figure 5-6 from paper
          {0.8f, {0.2f, 0.4f, 0.6f, 0.8f}}
        };

        // Sample counts to test
        std::vector<uint32_t> sampleCounts = { 1, 2, 4, 8, 16, 32, 64, 128, 256, 512 };

        // High-quality reference sample count
        uint32_t referenceSamples = 4096;
    };

    //--------------------------------------------------------------------------------------------------
    // VNDF Analyzer
    //
    // Analyzes Bounded VNDF sampling efficiency for Smith-GGX reflections
    // Usage:
    //   1. Capture high-SPP reference image
    //   2. Start analysis session (Standard or Bounded VNDF)
    //   3. Test across roughness values
    //   4. Export results to CSV for plotting
    //--------------------------------------------------------------------------------------------------
    class VNDFAnalyzer
    {
    public:
        VNDFAnalyzer() = default;
        ~VNDFAnalyzer() { destroy(); }

        // Initialize analyzer
        void init(nvvk::ResourceAllocator& allocator, VkDevice device, VkExtent2D resolution);
        void destroy();

        //----------------------------------------------------------------------------------------------
        // Reference Image Management
        //----------------------------------------------------------------------------------------------

        // Capture reference image (high-quality ground truth)
        void captureReference(VkCommandBuffer cmd, VkImage sourceImage, VkExtent2D extent);
        void finalizeReferenceCapture();

        // Load/save reference from disk
        void loadReference(const std::string& filepath);
        void saveReference(const std::string& filepath);

        //----------------------------------------------------------------------------------------------
        // Analysis Session Management
        //----------------------------------------------------------------------------------------------

        // Start new analysis session
        void startSession(const std::string& sessionName, bool useBoundedVNDF, float roughness,
            bool isAnisotropic = false, float alphaX = 0.0f, float alphaY = 0.0f);

        // Capture metrics for current frame
        void captureFrame(VkCommandBuffer cmd, VkImage sourceImage, uint32_t sampleCount,
            uint64_t totalSamples, uint64_t rejectedSamples, double renderTimeMs);

        void finalizeFrameCapture();
        void endSession();

        //----------------------------------------------------------------------------------------------
        // Batch Testing
        //----------------------------------------------------------------------------------------------

        // Run complete test suite
        void runIsotropicTests(const VNDFTestConfig& config);
        void runAnisotropicTests(const VNDFTestConfig& config);

        //----------------------------------------------------------------------------------------------
        // Metrics Access
        //----------------------------------------------------------------------------------------------

        const std::vector<VNDFMetrics>& getMetrics() const { return m_metrics; }
        bool isSessionActive() const { return m_sessionActive; }
        std::string getSessionName() const { return m_sessionName; }

        // Get specific metric comparisons
        float getRejectionRateImprovement() const;  // % reduction in rejection rate
        float getRMSEImprovement() const;           // % reduction in RMSE
        float getOverheadPercentage() const;        // % increase in render time

        //----------------------------------------------------------------------------------------------
        // Export & Visualization
        //----------------------------------------------------------------------------------------------

        // Export analysis results
        void exportToCSV(const std::string& filepath);
        void exportComparisonImages(const std::string& directory);
        void exportPlots(const std::string& directory);  // Generate matplotlib-ready data

        // Export false-color error maps
        void exportErrorMap(const std::string& filepath, const std::vector<float>& testImage);

    private:
        // Image I/O helpers
        void recordImageDownload(VkCommandBuffer cmd, VkImage image, VkExtent2D extent);
        std::vector<float> readStagingBuffer(VkExtent2D extent);
        void saveImage(const std::string& filepath, const std::vector<float>& data,
            uint32_t width, uint32_t height);
        std::vector<float> loadImage(const std::string& filepath, uint32_t& width, uint32_t& height);

        // Metrics computation
        static double computeMSE(const std::vector<float>& img1, const std::vector<float>& img2,
            uint32_t width, uint32_t height);
        static double computeRMSE(double mse);
        static double computePSNR(double mse);

        // Generate false-color error visualization
        std::vector<uint8_t> generateErrorMap(const std::vector<float>& testImage,
            const std::vector<float>& refImage,
            uint32_t width, uint32_t height, float maxError = 0.1f);

    private:
        nvvk::ResourceAllocator* m_allocator{ nullptr };
        VkDevice                 m_device{ VK_NULL_HANDLE };
        VkExtent2D               m_resolution{};

        // Reference image (ground truth)
        std::vector<float> m_referenceImage;
        bool               m_hasReference{ false };

        // Current session state
        bool        m_sessionActive{ false };
        std::string m_sessionName;
        bool        m_useBoundedVNDF{ false };
        float       m_currentRoughness{ 0.0f };
        bool        m_isAnisotropic{ false };
        float       m_currentAlphaX{ 0.0f };
        float       m_currentAlphaY{ 0.0f };

        // Pending capture (for async GPU operations)
        uint32_t m_pendingSampleCount{ 0 };
        uint64_t m_pendingTotalSamples{ 0 };
        uint64_t m_pendingRejectedSamples{ 0 };
        double   m_pendingRenderTimeMs{ 0.0 };

        // Session start time for elapsed time tracking
        std::chrono::steady_clock::time_point m_sessionStartTime;

        // Captured metrics and frames
        std::vector<VNDFMetrics> m_metrics;

        struct CapturedFrame {
            uint32_t           sampleCount;
            float              roughness;
            std::vector<float> data;
        };
        std::vector<CapturedFrame> m_capturedFrames;

        // Staging buffer for GPU->CPU image transfers
        nvvk::Buffer m_stagingBuffer;
    };

}  // namespace matforge