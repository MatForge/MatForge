/*
 * Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)
 *
 * RMIP Analyzer for PRI (Psi-guided Ray Intersection) Marching Performance Testing
 * Compares brute force vs psi-guided texel marching for displacement mapping
 *
 * Based on: "Displacement ray-tracing via inversion and oblong bounding" (SIGGRAPH Asia 2023)
 */

#pragma once

#include <vector>
#include <string>
#include <chrono>
#include <vulkan/vulkan_core.h>
#include <nvvk/resource_allocator.hpp>

namespace matforge {

    //--------------------------------------------------------------------------------------------------
    // RMIP Marching Method Types
    //--------------------------------------------------------------------------------------------------
    enum class RMIPMethod
    {
        BruteForce,     // Test all texels in region (reliable baseline)
        PsiMarching     // Psi-guided texel marching (paper algorithm)
    };

    //--------------------------------------------------------------------------------------------------
    // RMIP Test Metrics
    //--------------------------------------------------------------------------------------------------
    struct RMIPMetrics
    {
        RMIPMethod  method{ RMIPMethod::BruteForce };
        uint32_t    sampleCount{ 0 };           // Samples per pixel at this capture

        // Configuration parameters
        int         maxTraversalIters{ 2560 };  // rmipMaxTraversalIters
        float       marchingScale{ 2.0f };      // rmipMarchingScale (leaf region size in texels)
        int         maxStackSize{ 32 };         // rmipMaxStackSize

        // Quality metrics (compared to reference)
        double      mse{ 0.0 };                 // Mean Squared Error
        double      rmse{ 0.0 };                // Root Mean Squared Error
        double      psnr{ 0.0 };                // Peak Signal-to-Noise Ratio
        double      ssim{ 0.0 };                // Structural Similarity Index

        // Performance metrics
        double      renderTimeMs{ 0.0 };        // Frame render time
        double      avgIterations{ 0.0 };       // Average traversal iterations per ray (if tracked)
        double      avgTexelsTested{ 0.0 };     // Average texels tested per ray (if tracked)

        // Artifact detection
        bool        hasHoles{ false };          // Missing hits (psi-marching stripping)
        bool        hasIncorrectHits{ false };  // Wrong hit points
        double      holePercentage{ 0.0 };      // Percentage of pixels with holes vs reference

        // Scene info
        std::string sceneName;                  // Name of test scene
        int         triangleCount{ 0 };         // Number of displaced triangles
        int         textureResolution{ 0 };     // Displacement map resolution

        std::string notes;                      // Additional observations
    };

    //--------------------------------------------------------------------------------------------------
    // RMIP Test Configuration
    //--------------------------------------------------------------------------------------------------
    struct RMIPTestConfig
    {
        // Marching scale values to test (leaf region size in texels)
        std::vector<float> marchingScales{ 1.0f, 2.0f, 4.0f, 8.0f, 16.0f };

        // Max traversal iterations to test
        std::vector<int> maxIterValues{ 512, 1024, 2048, 4096 };

        // Stack sizes to test
        std::vector<int> stackSizes{ 16, 32, 64 };

        // Sample counts for convergence testing
        std::vector<uint32_t> sampleCounts{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512 };

        // High-quality reference sample count
        uint32_t referenceSamples{ 4096 };

        // Output settings
        std::string outputDirectory{ "rmip_analysis" };
        bool exportImages{ true };
        bool exportCSV{ true };
    };

    //--------------------------------------------------------------------------------------------------
    // RMIP Analyzer
    //
    // Performance analysis framework for PRI (Psi-guided Ray Intersection) marching
    //
    // Usage:
    //   1. Capture high-SPP reference with brute force method
    //   2. Test psi-marching with various parameters
    //   3. Compare quality and performance
    //   4. Export results for analysis
    //
    // Key Tests:
    //   - Brute Force vs Psi-Marching quality comparison
    //   - Effect of marchingScale on quality/performance
    //   - Effect of maxTraversalIters on convergence
    //   - Hole detection (stripping artifacts in psi-marching)
    //--------------------------------------------------------------------------------------------------
    class RMIPAnalyzer
    {
    public:
        RMIPAnalyzer() = default;
        ~RMIPAnalyzer() { destroy(); }

        // Initialize analyzer
        void init(nvvk::ResourceAllocator& allocator, VkDevice device, VkExtent2D resolution);
        void destroy();

        //----------------------------------------------------------------------------------------------
        // Reference Image Management
        //----------------------------------------------------------------------------------------------

        // Capture reference image (high-quality brute force ground truth)
        void captureReference(VkCommandBuffer cmd, VkImage sourceImage, VkExtent2D extent);
        void finalizeReferenceCapture();

        // Load/save reference from disk
        void loadReference(const std::string& filepath);
        void saveReference(const std::string& filepath);

        //----------------------------------------------------------------------------------------------
        // Analysis Session Management
        //----------------------------------------------------------------------------------------------

        // Start new analysis session
        void startSession(const std::string& sessionName, RMIPMethod method,
                          int maxTraversalIters, float marchingScale, int maxStackSize);

        // Capture metrics for current frame
        void captureFrame(VkCommandBuffer cmd, VkImage sourceImage,
                          uint32_t sampleCount, double renderTimeMs);

        void finalizeFrameCapture();
        void endSession();

        // Session state
        bool isSessionActive() const { return m_sessionActive; }
        std::string getSessionName() const { return m_sessionName; }

        // Current test parameters
        RMIPMethod getCurrentMethod() const { return m_currentMethod; }
        int getCurrentMaxIters() const { return m_currentMaxIters; }
        float getCurrentMarchingScale() const { return m_currentMarchingScale; }
        int getCurrentStackSize() const { return m_currentStackSize; }

        //----------------------------------------------------------------------------------------------
        // Metrics Computation
        //----------------------------------------------------------------------------------------------

        // Compute MSE between test and reference
        static double computeMSE(const std::vector<float>& test, const std::vector<float>& ref,
                                 uint32_t width, uint32_t height);

        // Compute RMSE from MSE
        static double computeRMSE(double mse);

        // Compute PSNR from MSE
        static double computePSNR(double mse);

        // Compute SSIM (Structural Similarity)
        static double computeSSIM(const std::vector<float>& test, const std::vector<float>& ref,
                                  uint32_t width, uint32_t height);

        // Detect holes (pixels that are significantly darker than reference)
        static double computeHolePercentage(const std::vector<float>& test, const std::vector<float>& ref,
                                            uint32_t width, uint32_t height, float threshold = 0.1f);

        //----------------------------------------------------------------------------------------------
        // Results Access
        //----------------------------------------------------------------------------------------------

        // Clear all captured metrics
        void clearMetrics();

        // Get all captured metrics
        const std::vector<RMIPMetrics>& getMetrics() const { return m_metrics; }

        // Get metrics for specific configuration
        RMIPMetrics* getMetrics(RMIPMethod method, float marchingScale, int maxIters);

        // Get method name string
        static std::string getMethodName(RMIPMethod method);

        //----------------------------------------------------------------------------------------------
        // Export & Visualization
        //----------------------------------------------------------------------------------------------

        // Export all metrics to CSV
        void exportMetricsCSV(const std::string& filepath);

        // Export metrics for specific method
        void exportMetricsCSV(const std::string& filepath, RMIPMethod method);

        // Export performance comparison (render time vs marchingScale)
        void exportPerformanceCSV(const std::string& filepath);

        // Export quality comparison (PSNR vs marchingScale)
        void exportQualityCSV(const std::string& filepath);

        // Export hole analysis (hole percentage vs parameters)
        void exportHoleAnalysisCSV(const std::string& filepath);

        // Export comparison images
        void exportComparisonImages(const std::string& directory);

        // Export difference/error map
        void exportErrorMap(const std::string& filepath, const std::vector<float>& testImage);

        // Generate Python plotting script
        void generatePlotScript(const std::string& filepath);

    private:
        // Image I/O helpers
        void readStagingBuffer(std::vector<float>& outData);
        void saveImage(const std::string& filepath, const std::vector<float>& data);
        std::vector<float> loadImage(const std::string& filepath, uint32_t& width, uint32_t& height);

        // Generate false-color error visualization
        std::vector<uint8_t> generateErrorMap(const std::vector<float>& testImage,
                                              const std::vector<float>& refImage,
                                              uint32_t width, uint32_t height, float maxError = 0.1f);

    private:
        nvvk::ResourceAllocator* m_allocator{ nullptr };
        VkDevice                 m_device{ VK_NULL_HANDLE };
        VkExtent2D               m_resolution{};

        // Reference image (ground truth - brute force at high SPP)
        std::vector<float> m_referenceImage;
        bool               m_hasReference{ false };

        // Current session state
        bool        m_sessionActive{ false };
        std::string m_sessionName;
        RMIPMethod  m_currentMethod{ RMIPMethod::BruteForce };
        int         m_currentMaxIters{ 2560 };
        float       m_currentMarchingScale{ 2.0f };
        int         m_currentStackSize{ 32 };

        // Pending capture (for async GPU operations)
        uint32_t m_pendingSampleCount{ 0 };
        double   m_pendingRenderTimeMs{ 0.0 };

        // Session start time
        std::chrono::steady_clock::time_point m_sessionStartTime;

        // Captured metrics
        std::vector<RMIPMetrics> m_metrics;

        // Captured frames for comparison
        struct CapturedFrame {
            RMIPMethod         method;
            float              marchingScale;
            int                maxIters;
            uint32_t           sampleCount;
            std::vector<float> data;
        };
        std::vector<CapturedFrame> m_capturedFrames;

        // Staging buffer for GPU->CPU image transfers
        nvvk::Buffer m_stagingBuffer;

        // Test configuration (stored for export)
        RMIPTestConfig m_config;
    };

}  // namespace matforge
