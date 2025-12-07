/*
 * Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)
 *
 * MSX Analyzer for Fast-MSX Multiple Scattering Testing
 * Validates Fast-MSX implementation against paper results and reference methods
 */

#pragma once

#include <vector>
#include <string>
#include <functional>
#include <unordered_map>
#include <chrono>
#include <vulkan/vulkan_core.h>
#include <glm/glm.hpp>
#include <nvvk/resource_allocator.hpp>

namespace matforge {

    //--------------------------------------------------------------------------------------------------
    // MSX Method Types
    //--------------------------------------------------------------------------------------------------
    enum class MSXMethod
    {
        GGX,          // Walter et al. 2007 - Single bounce baseline
        FastMSX,      // Our Fast-MSX implementation
        HeitzMS,      // Heitz et al. 2016 - Stochastic ground truth (if available)
        LeeMS,        // Lee et al. 2018 - Zipin-based closed form
        WangMS,       // Wang et al. 2022 - Position-free
        TurquinMS     // Turquin 2018 - Energy compensation
    };

    //--------------------------------------------------------------------------------------------------
    // Material Types for Testing
    //--------------------------------------------------------------------------------------------------
    enum class TestMaterial
    {
        Achromatic,  // Grayscale (albedo = 0.5)
        Copper,      // Typical metal
        Gold,        // Typical metal
        Custom       // User-defined F0
    };

    //--------------------------------------------------------------------------------------------------
    // MSX Test Metrics
    //--------------------------------------------------------------------------------------------------
    struct MSXMetrics
    {
        bool        useFastMSX{ false };       // false = GGX (baseline), true = FastMSX
        TestMaterial material{ TestMaterial::Achromatic };
        float       roughness{ 0.5f };         // Alpha value (0.0 - 1.0)
        uint32_t    sampleCount{ 512 };        // SPP used for this render

        // Quality metrics (compared to reference)
        double      mse{ 0.0 };                // Mean Squared Error
        double      psnr{ 0.0 };               // Peak Signal-to-Noise Ratio
        double      ssim{ 0.0 };               // Structural Similarity Index

        // Energy metrics
        double      energyLoss{ 0.0 };         // Energy loss compared to ideal
        double      furnaceTestError{ 0.0 };   // Deviation from 1.0 in furnace test

        // Performance metrics
        double      renderTimeMs{ 0.0 };       // Time to render this frame
        double      shaderTimeUs{ 0.0 };       // Per-pixel shader execution time (if available)

        // Visual quality flags
        bool        hasArtifacts{ false };     // Manual flag for artifact detection
        bool        hasSpecularPeak{ false };  // Lee et al. style mirror artifacts
        bool        isTooDark{ false };        // Insufficient energy recovery

        std::string notes;                   // Additional observations
    };

    //--------------------------------------------------------------------------------------------------
    // MSX Test Configuration
    //--------------------------------------------------------------------------------------------------
    struct MSXTestConfig
    {
        // Test parameters
        std::vector<float>        roughnessValues{ 0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f, 0.7f, 0.8f, 0.9f, 1.0f };
        std::vector<TestMaterial> materials{ TestMaterial::Achromatic, TestMaterial::Copper, TestMaterial::Gold };
        // Note: Tests both GGX (useFastMSX=false) and FastMSX (useFastMSX=true) automatically

        // Render settings
        uint32_t    samplesPerPixel{ 512 };
        VkExtent2D  resolution{ 512, 512 };

        // Reference sample count (high quality ground truth)
        uint32_t    referenceSPP{ 4096 };

        // Test scene
        std::string sceneName{ "shaderball" };
        std::string hdriPath{ "studio_small_09_2k.hdr" };

        // Furnace test
        bool        runFurnaceTest{ true };

        // Output
        std::string outputDirectory{ "msx_analysis" };
        bool        exportImages{ true };
        bool        exportCSV{ true };
        bool        generatePlots{ true };
    };

    //--------------------------------------------------------------------------------------------------
    // MSX Analyzer
    //
    // Comprehensive testing framework for Fast-MSX multiple scattering implementation
    // 
    // Usage:
    //   1. Configure test parameters (roughness values, materials, methods)
    //   2. Set reference renders (high-quality ground truth)
    //   3. Run test suite across all combinations
    //   4. Compute quality and performance metrics
    //   5. Export results (CSV, images, plots)
    //   6. Validate against paper results (Figure 9, Figure 14)
    //
    // Key Tests:
    //   - MSE vs Roughness (Figure 9 from paper)
    //   - Visual quality comparison (Figure 14)
    //   - Furnace test (Figure 10a)
    //   - Performance comparison (Figure 9 bottom)
    //   - Artifact detection (Figure 5)
    //--------------------------------------------------------------------------------------------------
    class MSXAnalyzer
    {
    public:
        MSXAnalyzer() = default;
        ~MSXAnalyzer() { destroy(); }

        // Initialize analyzer
        void init(nvvk::ResourceAllocator& allocator, VkDevice device, const MSXTestConfig& config);
        void destroy();

        //----------------------------------------------------------------------------------------------
        // Async Session Management (for render loop integration)
        //----------------------------------------------------------------------------------------------

        // Capture reference image (high-quality ground truth)
        void captureReference(VkCommandBuffer cmd, VkImage sourceImage, VkExtent2D extent);
        void finalizeReferenceCapture();

        // Load/save reference sets for batch testing
        void loadReferenceSet(const std::string& directory);
        void saveReferenceSet(const std::string& directory);

        // Start new analysis session
        void startSession(const std::string& sessionName, bool useFastMSX, TestMaterial material, float roughness);

        // Capture metrics for current frame (records GPU commands)
        void captureFrame(VkCommandBuffer cmd, VkImage sourceImage, uint32_t sampleCount, double renderTimeMs);

        // Finalize frame capture after GPU sync
        void finalizeFrameCapture();

        // End current session
        void endSession();

        // Check if session is active
        bool isSessionActive() const { return m_sessionActive; }
        std::string getSessionName() const { return m_sessionName; }

        // Get current test parameters
        bool isUsingFastMSX() const { return m_useFastMSX; }
        TestMaterial getCurrentMaterial() const { return m_currentMaterial; }
        float getCurrentRoughness() const { return m_currentRoughness; }

        //----------------------------------------------------------------------------------------------
        // Metrics Computation
        //----------------------------------------------------------------------------------------------

        // Compute MSE between test and reference
        static double computeMSE(const std::vector<float>& test, const std::vector<float>& ref,
            uint32_t width, uint32_t height);

        // Compute PSNR from MSE
        static double computePSNR(double mse);

        // Compute SSIM (Structural Similarity)
        static double computeSSIM(const std::vector<float>& test, const std::vector<float>& ref,
            uint32_t width, uint32_t height);

        // Compute energy loss (1.0 - total energy)
        static double computeEnergyLoss(const std::vector<float>& image, uint32_t width, uint32_t height);

        // Compute furnace test error (deviation from uniform white)
        static double computeFurnaceTestError(const std::vector<float>& image, uint32_t width, uint32_t height);

        // Detect specular artifacts (Lee et al. style peaks)
        static bool detectSpecularArtifacts(const std::vector<float>& image, uint32_t width, uint32_t height,
            float roughness);

        //----------------------------------------------------------------------------------------------
        // Export & Visualization
        //----------------------------------------------------------------------------------------------

        // Export all metrics to CSV (for plotting in Python/Excel)
        void exportMetricsCSV(const std::string& filepath);

        // Export metrics for a specific method only
        void exportMetricsCSV(const std::string& filepath, bool useFastMSX);

        // Export MSE vs Roughness plot data (Figure 9 style)
        void exportMSEvsRoughnessCSV(const std::string& filepath);

        // Export performance comparison data
        void exportPerformanceCSV(const std::string& filepath);

        // Export side-by-side comparison images
        void exportComparisonImages(const std::string& directory);

        // Export grid of all results (Figure 14 style)
        void exportResultGrid(const std::string& filepath, const std::vector<float>& roughnessValues);

        // Export furnace test results
        void exportFurnaceTestResults(const std::string& directory);

        // Generate Python plotting script
        void generatePlotScript(const std::string& filepath);

        //----------------------------------------------------------------------------------------------
        // Results Access
        //----------------------------------------------------------------------------------------------

        // Clear all captured metrics and frames (call before starting a new test run)
        void clearMetrics();

        // Get all captured metrics
        const std::vector<MSXMetrics>& getMetrics() const { return m_metrics; }

        // Get metrics for specific test case
        MSXMetrics* getMetrics(bool useFastMSX, TestMaterial material, float roughness);

        // Get test summary statistics
        struct TestSummary
        {
            double avgMSE{ 0.0 };
            double avgPSNR{ 0.0 };
            double avgRenderTime{ 0.0 };
            int    artifactCount{ 0 };
            int    totalTests{ 0 };
        };
        TestSummary getTestSummary(bool useFastMSX) const;

        // Check if test is complete
        bool isTestComplete() const { return m_testComplete; }
        float getTestProgress() const { return m_testProgress; }

    private:
        //----------------------------------------------------------------------------------------------
        // Internal Helpers
        //----------------------------------------------------------------------------------------------

        // Download image from GPU to CPU (records GPU commands)
        std::vector<float> downloadImage(VkCommandBuffer cmd, VkImage image);

        // Read staging buffer after GPU sync completes
        void readStagingBuffer(std::vector<float>& outData);

        // Save image to file (HDR format for accurate comparison)
        void saveImage(const std::string& filepath, const std::vector<float>& data);

        // Load image from file
        std::vector<float> loadImage(const std::string& filepath, uint32_t& width, uint32_t& height);

        // Get reference image key
        std::string getReferenceKey(TestMaterial material, float roughness) const;

        // Find or create reference image
        const std::vector<float>* getReference(TestMaterial material, float roughness);

        // Record timing measurement
        void recordTiming(MSXMethod method, double timeMs);

    public:
        // Generate material name string (public for callbacks)
        static std::string getMaterialName(TestMaterial material);

        // Generate method name string (public for callbacks)
        static std::string getMethodName(MSXMethod method);

    private:

        // Setup furnace test environment
        void setupFurnaceTest();

        // Restore normal test environment
        void restoreFurnaceTest();

    private:
        nvvk::ResourceAllocator* m_allocator{ nullptr };
        VkDevice                 m_device{ VK_NULL_HANDLE };
        MSXTestConfig            m_config{};
        VkExtent2D               m_resolution{};

        // Reference image (ground truth)
        std::vector<float> m_referenceImage;
        bool               m_hasReference{ false };

        // Reference images (key: "material_roughness") for batch tests
        std::unordered_map<std::string, std::vector<float>> m_referenceImages;
        bool m_hasReferences{ false };

        // Captured test results
        std::vector<MSXMetrics> m_metrics;

        // Current session state
        bool         m_sessionActive{ false };
        std::string  m_sessionName;
        bool         m_useFastMSX{ false };
        TestMaterial m_currentMaterial{ TestMaterial::Achromatic };
        float        m_currentRoughness{ 0.5f };

        // Pending capture (for async GPU operations)
        uint32_t m_pendingSampleCount{ 0 };
        double   m_pendingRenderTimeMs{ 0.0 };

        // Session timing
        std::chrono::steady_clock::time_point m_sessionStartTime;

        // Current test state (for batch tests)
        bool   m_testActive{ false };
        bool   m_testComplete{ false };
        float  m_testProgress{ 0.0f };
        size_t m_currentTestIndex{ 0 };
        size_t m_totalTests{ 0 };

        // Captured frames for comparison
        struct CapturedFrame
        {
            bool               useFastMSX;
            TestMaterial       material;
            float              roughness;
            std::vector<float> data;
        };
        std::vector<CapturedFrame> m_capturedFrames;

        // Staging buffer for image download
        nvvk::Buffer m_stagingBuffer;

        // Furnace test state
        bool m_furnaceTestActive{ false };
        VkImage m_savedHDRI{ VK_NULL_HANDLE };
    };

    //--------------------------------------------------------------------------------------------------
    // Helper Functions
    //--------------------------------------------------------------------------------------------------

    // Convert material to Fresnel F0 values
    inline glm::vec3 getMaterialF0(TestMaterial material)
    {
        switch (material)
        {
        case TestMaterial::Achromatic: return glm::vec3(0.5f);
        case TestMaterial::Copper:     return glm::vec3(0.955f, 0.638f, 0.538f);  // From paper
        case TestMaterial::Gold:       return glm::vec3(1.000f, 0.766f, 0.336f);  // From paper
        case TestMaterial::Custom:     return glm::vec3(0.5f);
        default:                       return glm::vec3(0.5f);
        }
    }

    // Check if method is available
    inline bool isMethodAvailable(MSXMethod method)
    {
        // You might not have all methods implemented
        switch (method)
        {
        case MSXMethod::GGX:      return true;   // Should always be available
        case MSXMethod::FastMSX:  return true;   // Your implementation
        case MSXMethod::HeitzMS:  return false;  // May need external implementation
        case MSXMethod::LeeMS:    return false;  // May need external implementation
        case MSXMethod::WangMS:   return false;  // May need external implementation
        case MSXMethod::TurquinMS: return false; // May need external implementation
        default:                  return false;
        }
    }

}  // namespace matforge
