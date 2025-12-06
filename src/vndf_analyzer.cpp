/*
 * Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)
 */

#include <volk.h>
#include "vndf_analyzer.hpp"
#include <fstream>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>

 // STB image I/O
#include <stb_image_write.h>
#include <stb_image.h>

namespace matforge {

    //--------------------------------------------------------------------------------------------------
    // Initialization
    //--------------------------------------------------------------------------------------------------
    void VNDFAnalyzer::init(nvvk::ResourceAllocator& allocator, VkDevice device, VkExtent2D resolution)
    {
        m_allocator = &allocator;
        m_device = device;
        m_resolution = resolution;

        // Create staging buffer for image downloads (RGBA32F)
        VkDeviceSize bufferSize = resolution.width * resolution.height * 4 * sizeof(float);
        m_allocator->createBuffer(m_stagingBuffer, bufferSize,
            VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VMA_MEMORY_USAGE_GPU_TO_CPU);

        // Map the staging buffer persistently
        void* mapped = nullptr;
        VkResult result = vmaMapMemory(*m_allocator, m_stagingBuffer.allocation, &mapped);
        if (result == VK_SUCCESS)
        {
            m_stagingBuffer.mapping = static_cast<uint8_t*>(mapped);
            printf("VNDF Analyzer: Staging buffer mapped successfully (%llu bytes)\n",
                (unsigned long long)bufferSize);
        }
        else
        {
            printf("Error: Failed to map staging buffer (VkResult: %d)\n", result);
        }
    }

    void VNDFAnalyzer::destroy()
    {
        if (m_allocator && m_stagingBuffer.buffer != VK_NULL_HANDLE)
        {
            if (m_stagingBuffer.mapping != nullptr)
            {
                vmaUnmapMemory(*m_allocator, m_stagingBuffer.allocation);
                m_stagingBuffer.mapping = nullptr;
            }
            m_allocator->destroyBuffer(m_stagingBuffer);
        }
        m_allocator = nullptr;
        m_device = VK_NULL_HANDLE;
    }

    //--------------------------------------------------------------------------------------------------
    // Reference Image Management
    //--------------------------------------------------------------------------------------------------
    void VNDFAnalyzer::captureReference(VkCommandBuffer cmd, VkImage sourceImage, VkExtent2D extent)
    {
        recordImageDownload(cmd, sourceImage, extent);
        m_resolution = extent;

        printf("VNDF Analyzer: Reference download recorded (%ux%u) - waiting for GPU sync...\n",
            extent.width, extent.height);
    }

    void VNDFAnalyzer::finalizeReferenceCapture()
    {
        m_referenceImage = readStagingBuffer(m_resolution);
        m_hasReference = true;

        printf("VNDF Analyzer: Reference image finalized (%ux%u)\n",
            m_resolution.width, m_resolution.height);
    }

    void VNDFAnalyzer::loadReference(const std::string& filepath)
    {
        uint32_t width, height;
        m_referenceImage = loadImage(filepath, width, height);
        m_hasReference = true;
        m_resolution = { width, height };

        printf("VNDF Analyzer: Reference loaded from %s (%ux%u)\n",
            filepath.c_str(), width, height);
    }

    void VNDFAnalyzer::saveReference(const std::string& filepath)
    {
        if (!m_hasReference)
        {
            printf("Error: No reference image to save\n");
            return;
        }

        saveImage(filepath, m_referenceImage, m_resolution.width, m_resolution.height);
        printf("VNDF Analyzer: Reference saved to %s\n", filepath.c_str());
    }

    //--------------------------------------------------------------------------------------------------
    // Session Management
    //--------------------------------------------------------------------------------------------------
    void VNDFAnalyzer::startSession(const std::string& sessionName, bool useBoundedVNDF,
        float roughness, bool isAnisotropic, float alphaX, float alphaY)
    {
        if (!m_hasReference)
        {
            printf("Error: Cannot start VNDF analysis without reference image\n");
            return;
        }

        m_sessionActive = true;
        m_sessionName = sessionName;
        m_useBoundedVNDF = useBoundedVNDF;
        m_currentRoughness = roughness;
        m_isAnisotropic = isAnisotropic;
        m_currentAlphaX = alphaX;
        m_currentAlphaY = alphaY;
        m_sessionStartTime = std::chrono::steady_clock::now();

        m_metrics.clear();
        m_capturedFrames.clear();

        if (isAnisotropic)
        {
            printf("VNDF Analyzer: Session started: %s (αₓ=%.2f, αᵧ=%.2f, %s)\n",
                sessionName.c_str(), alphaX, alphaY,
                useBoundedVNDF ? "Bounded VNDF" : "Standard VNDF");
        }
        else
        {
            printf("VNDF Analyzer: Session started: %s (α=%.2f, %s)\n",
                sessionName.c_str(), roughness,
                useBoundedVNDF ? "Bounded VNDF" : "Standard VNDF");
        }
    }

    void VNDFAnalyzer::captureFrame(VkCommandBuffer cmd, VkImage sourceImage, uint32_t sampleCount,
        uint64_t totalSamples, uint64_t rejectedSamples, double renderTimeMs)
    {
        if (!m_sessionActive)
        {
            printf("Error: No active VNDF analysis session\n");
            return;
        }

        // Record GPU image download
        recordImageDownload(cmd, sourceImage, m_resolution);

        // Store pending capture info
        m_pendingSampleCount = sampleCount;
        m_pendingTotalSamples = totalSamples;
        m_pendingRejectedSamples = rejectedSamples;
        m_pendingRenderTimeMs = renderTimeMs;
    }

    void VNDFAnalyzer::finalizeFrameCapture()
    {
        if (!m_sessionActive)
        {
            printf("Error: No active VNDF analysis session\n");
            return;
        }

        // Read from staging buffer (after GPU copy completes)
        std::vector<float> frameData = readStagingBuffer(m_resolution);

        // Compute metrics
        VNDFMetrics metrics;
        metrics.sampleCount = m_pendingSampleCount;
        metrics.roughnessAlpha = m_currentRoughness;
        metrics.roughnessAlphaX = m_currentAlphaX;
        metrics.roughnessAlphaY = m_currentAlphaY;
        metrics.isAnisotropic = m_isAnisotropic;
        metrics.totalSamples = m_pendingTotalSamples;
        metrics.rejectedSamples = m_pendingRejectedSamples;
        metrics.rejectionRate = (m_pendingTotalSamples > 0) ?
            (float(m_pendingRejectedSamples) / float(m_pendingTotalSamples) * 100.0f) : 0.0f;
        metrics.mse = computeMSE(frameData, m_referenceImage,
            m_resolution.width, m_resolution.height);
        metrics.rmse = computeRMSE(metrics.mse);
        metrics.psnr = computePSNR(metrics.mse);
        metrics.renderTimeMs = m_pendingRenderTimeMs;
        metrics.useBoundedVNDF = m_useBoundedVNDF;

        // Calculate elapsed time
        auto now = std::chrono::steady_clock::now();
        metrics.captureTimeMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - m_sessionStartTime).count();

        // Quality-per-time metric (higher is better)
        if (metrics.rmse > 0.0 && metrics.renderTimeMs > 0.0)
        {
            metrics.qualityPerTime = (1.0 / metrics.rmse) * (1000.0 / metrics.renderTimeMs);
        }

        m_metrics.push_back(metrics);

        // Store frame for comparison
        CapturedFrame frame;
        frame.sampleCount = m_pendingSampleCount;
        frame.roughness = m_currentRoughness;
        frame.data = frameData;
        m_capturedFrames.push_back(frame);

        printf("VNDF Analyzer: Captured α=%.2f @ %u spp (Rejection: %.2f%%, RMSE: %.6f)\n",
            m_currentRoughness, m_pendingSampleCount, metrics.rejectionRate, metrics.rmse);
    }

    void VNDFAnalyzer::endSession()
    {
        if (!m_sessionActive)
            return;

        m_sessionActive = false;
        printf("VNDF Analyzer: Session ended: %s (%zu captures)\n",
            m_sessionName.c_str(), m_metrics.size());
    }

    //--------------------------------------------------------------------------------------------------
    // Metrics Computation
    //--------------------------------------------------------------------------------------------------
    double VNDFAnalyzer::computeMSE(const std::vector<float>& img1, const std::vector<float>& img2,
        uint32_t width, uint32_t height)
    {
        if (img1.size() != img2.size())
        {
            printf("Error: Image size mismatch for MSE computation\n");
            return -1.0;
        }

        double mse = 0.0;
        size_t pixels = width * height;

        for (size_t i = 0; i < pixels; ++i)
        {
            // RGB channels only (skip alpha)
            float diffR = img1[i * 4 + 0] - img2[i * 4 + 0];
            float diffG = img1[i * 4 + 1] - img2[i * 4 + 1];
            float diffB = img1[i * 4 + 2] - img2[i * 4 + 2];

            mse += (diffR * diffR + diffG * diffG + diffB * diffB) / 3.0;
        }

        return mse / static_cast<double>(pixels);
    }

    double VNDFAnalyzer::computeRMSE(double mse)
    {
        return std::sqrt(mse);
    }

    double VNDFAnalyzer::computePSNR(double mse)
    {
        if (mse <= 0.0)
            return 100.0;  // Perfect match

        // PSNR = 10 * log10(MAX^2 / MSE), where MAX = 1.0 for HDR
        return 10.0 * std::log10(1.0 / mse);
    }

    //--------------------------------------------------------------------------------------------------
    // Metric Comparisons
    //--------------------------------------------------------------------------------------------------
    float VNDFAnalyzer::getRejectionRateImprovement() const
    {
        if (m_metrics.size() < 2)
            return 0.0f;

        // Find the most recent Standard and Bounded metrics for comparison
        const VNDFMetrics* standardMetric = nullptr;
        const VNDFMetrics* boundedMetric = nullptr;

        // Search backwards to find the most recent pair
        for (auto it = m_metrics.rbegin(); it != m_metrics.rend(); ++it)
        {
            if (it->useBoundedVNDF && !boundedMetric)
                boundedMetric = &(*it);
            else if (!it->useBoundedVNDF && !standardMetric)
                standardMetric = &(*it);

            if (standardMetric && boundedMetric)
                break;
        }

        if (!standardMetric || !boundedMetric)
        {
            printf("Warning: getRejectionRateImprovement() requires both Standard and Bounded metrics\n");
            return 0.0f;
        }

        float standardRate = standardMetric->rejectionRate;
        float boundedRate = boundedMetric->rejectionRate;

        if (standardRate <= 0.0f)
            return 0.0f;

        return ((standardRate - boundedRate) / standardRate) * 100.0f;
    }

    float VNDFAnalyzer::getRMSEImprovement() const
    {
        if (m_metrics.size() < 2)
            return 0.0f;

        // Find the most recent Standard and Bounded metrics for comparison
        const VNDFMetrics* standardMetric = nullptr;
        const VNDFMetrics* boundedMetric = nullptr;

        for (auto it = m_metrics.rbegin(); it != m_metrics.rend(); ++it)
        {
            if (it->useBoundedVNDF && !boundedMetric)
                boundedMetric = &(*it);
            else if (!it->useBoundedVNDF && !standardMetric)
                standardMetric = &(*it);

            if (standardMetric && boundedMetric)
                break;
        }

        if (!standardMetric || !boundedMetric)
        {
            printf("Warning: getRMSEImprovement() requires both Standard and Bounded metrics\n");
            return 0.0f;
        }

        double standardRMSE = standardMetric->rmse;
        double boundedRMSE = boundedMetric->rmse;

        if (standardRMSE <= 0.0)
            return 0.0f;

        return float((standardRMSE - boundedRMSE) / standardRMSE * 100.0);
    }

    float VNDFAnalyzer::getOverheadPercentage() const
    {
        if (m_metrics.size() < 2)
            return 0.0f;

        // Find the most recent Standard and Bounded metrics for comparison
        const VNDFMetrics* standardMetric = nullptr;
        const VNDFMetrics* boundedMetric = nullptr;

        for (auto it = m_metrics.rbegin(); it != m_metrics.rend(); ++it)
        {
            if (it->useBoundedVNDF && !boundedMetric)
                boundedMetric = &(*it);
            else if (!it->useBoundedVNDF && !standardMetric)
                standardMetric = &(*it);

            if (standardMetric && boundedMetric)
                break;
        }

        if (!standardMetric || !boundedMetric)
        {
            printf("Warning: getOverheadPercentage() requires both Standard and Bounded metrics\n");
            return 0.0f;
        }

        double standardTime = standardMetric->renderTimeMs;
        double boundedTime = boundedMetric->renderTimeMs;

        if (standardTime <= 0.0)
            return 0.0f;

        return float((boundedTime - standardTime) / standardTime * 100.0);
    }

    //--------------------------------------------------------------------------------------------------
    // Export
    //--------------------------------------------------------------------------------------------------
    void VNDFAnalyzer::exportToCSV(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            printf("Error: Could not open file for writing: %s\n", filepath.c_str());
            return;
        }

        // CSV header
        file << "SampleCount,Roughness,AlphaX,AlphaY,IsAnisotropic,"
            << "TotalSamples,RejectedSamples,RejectionRate(%),"
            << "MSE,RMSE,PSNR,"
            << "RenderTimeMs,QualityPerTime,"
            << "Method,ElapsedTimeMs\n";

        // Data rows
        for (const auto& metric : m_metrics)
        {
            file << metric.sampleCount << ","
                << metric.roughnessAlpha << ","
                << metric.roughnessAlphaX << ","
                << metric.roughnessAlphaY << ","
                << (metric.isAnisotropic ? "true" : "false") << ","
                << metric.totalSamples << ","
                << metric.rejectedSamples << ","
                << metric.rejectionRate << ","
                << metric.mse << ","
                << metric.rmse << ","
                << metric.psnr << ","
                << metric.renderTimeMs << ","
                << metric.qualityPerTime << ","
                << (metric.useBoundedVNDF ? "Bounded" : "Standard") << ","
                << metric.captureTimeMs << "\n";
        }

        file.close();
        printf("VNDF Analyzer: Exported to CSV: %s\n", filepath.c_str());
    }

    void VNDFAnalyzer::exportComparisonImages(const std::string& directory)
    {
        std::filesystem::create_directories(directory);

        for (const auto& frame : m_capturedFrames)
        {
            std::string filename = directory + "/" + m_sessionName +
                "_alpha" + std::to_string(int(frame.roughness * 100)) +
                "_" + std::to_string(frame.sampleCount) + "spp.png";
            saveImage(filename, frame.data, m_resolution.width, m_resolution.height);
        }

        printf("VNDF Analyzer: Exported %zu comparison images to %s\n",
            m_capturedFrames.size(), directory.c_str());
    }

    void VNDFAnalyzer::exportErrorMap(const std::string& filepath, const std::vector<float>& testImage)
    {
        if (!m_hasReference || testImage.empty())
        {
            printf("Error: Cannot export error map without reference and test images\n");
            return;
        }

        // Generate false-color error visualization
        std::vector<uint8_t> errorMap = generateErrorMap(testImage, m_referenceImage,
            m_resolution.width, m_resolution.height);

        // Save as PNG
        if (stbi_write_png(filepath.c_str(), m_resolution.width, m_resolution.height, 4,
            errorMap.data(), m_resolution.width * 4))
        {
            printf("VNDF Analyzer: Error map saved to %s\n", filepath.c_str());
        }
        else
        {
            printf("Error: Failed to save error map to %s\n", filepath.c_str());
        }
    }

    std::vector<uint8_t> VNDFAnalyzer::generateErrorMap(const std::vector<float>& testImage,
        const std::vector<float>& refImage,
        uint32_t width, uint32_t height, float maxError)
    {
        std::vector<uint8_t> errorMap(width * height * 4);

        for (size_t i = 0; i < width * height; ++i)
        {
            // Compute RGB error
            float diffR = std::abs(testImage[i * 4 + 0] - refImage[i * 4 + 0]);
            float diffG = std::abs(testImage[i * 4 + 1] - refImage[i * 4 + 1]);
            float diffB = std::abs(testImage[i * 4 + 2] - refImage[i * 4 + 2]);
            float error = (diffR + diffG + diffB) / 3.0f;

            // Normalize error to [0, 1]
            float normalizedError = std::min(error / maxError, 1.0f);

            // False-color mapping: Blue (low error) -> Green -> Yellow -> Red (high error)
            uint8_t r, g, b;
            if (normalizedError < 0.5f)
            {
                // Blue to Green
                float t = normalizedError * 2.0f;
                r = 0;
                g = static_cast<uint8_t>(t * 255);
                b = static_cast<uint8_t>((1.0f - t) * 255);
            }
            else
            {
                // Green to Red
                float t = (normalizedError - 0.5f) * 2.0f;
                r = static_cast<uint8_t>(t * 255);
                g = static_cast<uint8_t>((1.0f - t) * 255);
                b = 0;
            }

            errorMap[i * 4 + 0] = r;
            errorMap[i * 4 + 1] = g;
            errorMap[i * 4 + 2] = b;
            errorMap[i * 4 + 3] = 255;
        }

        return errorMap;
    }

    //--------------------------------------------------------------------------------------------------
    // Batch Testing
    //--------------------------------------------------------------------------------------------------
    void VNDFAnalyzer::runIsotropicTests(const VNDFTestConfig& config)
    {
        printf("VNDF Analyzer: Starting isotropic test suite (%zu roughness values, %zu sample counts)\n",
            config.roughnessValues.size(), config.sampleCounts.size());

        // Note: This function sets up the test configuration but actual captures
        // must be triggered externally via captureFrame() calls during rendering.
        // The caller should:
        //   1. For each roughness value in config.roughnessValues:
        //      a. Set material roughness
        //      b. For each sample count in config.sampleCounts:
        //         - Render with Standard VNDF, call captureFrame()
        //         - Render with Bounded VNDF, call captureFrame()
        //   2. Export results via exportToCSV()

        printf("  Test matrix:\n");
        printf("    Roughness values: ");
        for (float alpha : config.roughnessValues)
            printf("%.2f ", alpha);
        printf("\n");
        printf("    Sample counts: ");
        for (uint32_t spp : config.sampleCounts)
            printf("%u ", spp);
        printf("\n");
        printf("    Reference samples: %u\n", config.referenceSamples);
    }

    void VNDFAnalyzer::runAnisotropicTests(const VNDFTestConfig& config)
    {
        printf("VNDF Analyzer: Starting anisotropic test suite (%zu configurations)\n",
            config.anisotropicTests.size());

        // Note: This function sets up the test configuration but actual captures
        // must be triggered externally via captureFrame() calls during rendering.
        // The caller should:
        //   1. For each anisotropic config:
        //      a. Set material alphaX to config.fixedAlphaX
        //      b. For each alphaY in config.alphaYValues:
        //         - Set material alphaY
        //         - For each sample count:
        //           * Render with Standard VNDF, call captureFrame()
        //           * Render with Bounded VNDF, call captureFrame()
        //   2. Export results via exportToCSV()

        printf("  Test configurations:\n");
        for (size_t i = 0; i < config.anisotropicTests.size(); ++i)
        {
            const auto& test = config.anisotropicTests[i];
            printf("    Config %zu: alphaX=%.2f, alphaY values: ", i + 1, test.fixedAlphaX);
            for (float alphaY : test.alphaYValues)
                printf("%.2f ", alphaY);
            printf("\n");
        }
        printf("    Sample counts: ");
        for (uint32_t spp : config.sampleCounts)
            printf("%u ", spp);
        printf("\n");
    }

    void VNDFAnalyzer::exportPlots(const std::string& directory)
    {
        std::filesystem::create_directories(directory);

        // Format roughness for filename (e.g., 0.25 -> "alpha025")
        char roughnessStr[32];
        snprintf(roughnessStr, sizeof(roughnessStr), "alpha%03d", static_cast<int>(m_currentRoughness * 100 + 0.5f));

        // Export rejection rate vs roughness data
        std::string rejectionFile = directory + "/rejection_rate_" + roughnessStr + ".csv";
        std::ofstream rejFile(rejectionFile);
        if (rejFile.is_open())
        {
            rejFile << "Roughness,SampleCount,Method,RejectionRate\n";
            for (const auto& metric : m_metrics)
            {
                float roughness = metric.isAnisotropic ?
                    std::sqrt(metric.roughnessAlphaX * metric.roughnessAlphaY) :
                    metric.roughnessAlpha;
                rejFile << roughness << ","
                    << metric.sampleCount << ","
                    << (metric.useBoundedVNDF ? "Bounded" : "Standard") << ","
                    << metric.rejectionRate << "\n";
            }
            rejFile.close();
            printf("VNDF Analyzer: Exported rejection rate data to %s\n", rejectionFile.c_str());
        }

        // Export quality metrics (RMSE, PSNR) vs sample count
        std::string qualityFile = directory + "/quality_metrics_" + roughnessStr + ".csv";
        std::ofstream qualFile(qualityFile);
        if (qualFile.is_open())
        {
            qualFile << "Roughness,SampleCount,Method,RMSE,PSNR,RenderTimeMs\n";
            for (const auto& metric : m_metrics)
            {
                float roughness = metric.isAnisotropic ?
                    std::sqrt(metric.roughnessAlphaX * metric.roughnessAlphaY) :
                    metric.roughnessAlpha;
                qualFile << roughness << ","
                    << metric.sampleCount << ","
                    << (metric.useBoundedVNDF ? "Bounded" : "Standard") << ","
                    << metric.rmse << ","
                    << metric.psnr << ","
                    << metric.renderTimeMs << "\n";
            }
            qualFile.close();
            printf("VNDF Analyzer: Exported quality metrics to %s\n", qualityFile.c_str());
        }

        // Export anisotropic-specific data if present
        bool hasAnisotropic = false;
        for (const auto& metric : m_metrics)
        {
            if (metric.isAnisotropic)
            {
                hasAnisotropic = true;
                break;
            }
        }

        if (hasAnisotropic)
        {
            std::string anisoFile = directory + "/anisotropic_metrics_" + roughnessStr + ".csv";
            std::ofstream anisoOut(anisoFile);
            if (anisoOut.is_open())
            {
                anisoOut << "AlphaX,AlphaY,SampleCount,Method,RejectionRate,RMSE\n";
                for (const auto& metric : m_metrics)
                {
                    if (metric.isAnisotropic)
                    {
                        anisoOut << metric.roughnessAlphaX << ","
                            << metric.roughnessAlphaY << ","
                            << metric.sampleCount << ","
                            << (metric.useBoundedVNDF ? "Bounded" : "Standard") << ","
                            << metric.rejectionRate << ","
                            << metric.rmse << "\n";
                    }
                }
                anisoOut.close();
                printf("VNDF Analyzer: Exported anisotropic metrics to %s\n", anisoFile.c_str());
            }
        }

        printf("VNDF Analyzer: Plot data exported to %s\n", directory.c_str());
    }

    //--------------------------------------------------------------------------------------------------
    // Image I/O (similar to ConvergenceAnalyzer)
    //--------------------------------------------------------------------------------------------------
    void VNDFAnalyzer::recordImageDownload(VkCommandBuffer cmd, VkImage image, VkExtent2D extent)
    {
        // Resize staging buffer if resolution changed
        if (extent.width != m_resolution.width || extent.height != m_resolution.height)
        {
            if (m_stagingBuffer.buffer != VK_NULL_HANDLE)
            {
                if (m_stagingBuffer.mapping != nullptr)
                {
                    vmaUnmapMemory(*m_allocator, m_stagingBuffer.allocation);
                    m_stagingBuffer.mapping = nullptr;
                }
                m_allocator->destroyBuffer(m_stagingBuffer);
            }

            VkDeviceSize bufferSize = extent.width * extent.height * 4 * sizeof(float);
            m_allocator->createBuffer(m_stagingBuffer, bufferSize,
                VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                VMA_MEMORY_USAGE_GPU_TO_CPU);

            void* mapped = nullptr;
            VkResult result = vmaMapMemory(*m_allocator, m_stagingBuffer.allocation, &mapped);
            if (result == VK_SUCCESS)
            {
                m_stagingBuffer.mapping = static_cast<uint8_t*>(mapped);
            }

            m_resolution = extent;
        }

        // Transition image to TRANSFER_SRC_OPTIMAL
        VkImageMemoryBarrier barrier{ VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
        barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };

        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, nullptr, 0, nullptr, 1, &barrier);

        // Copy image to staging buffer
        VkBufferImageCopy region{};
        region.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        region.imageExtent = { extent.width, extent.height, 1 };

        vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            m_stagingBuffer.buffer, 1, &region);

        // Transition back to GENERAL
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;

        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0, 0, nullptr, 0, nullptr, 1, &barrier);
    }

    std::vector<float> VNDFAnalyzer::readStagingBuffer(VkExtent2D extent)
    {
        std::vector<float> data(extent.width * extent.height * 4);

        if (m_stagingBuffer.mapping != nullptr)
        {
            std::memcpy(data.data(), m_stagingBuffer.mapping, data.size() * sizeof(float));
        }
        else
        {
            printf("Warning: Staging buffer not mapped - returning empty data\n");
        }

        return data;
    }

    void VNDFAnalyzer::saveImage(const std::string& filepath, const std::vector<float>& data,
        uint32_t width, uint32_t height)
    {
        if (data.empty())
        {
            printf("Error: Cannot save empty image data\n");
            return;
        }

        std::filesystem::path path(filepath);
        std::string ext = path.extension().string();

        if (ext.empty())
        {
            ext = ".png";
            path += ext;
        }

        bool success = false;

        if (ext == ".hdr")
        {
            success = stbi_write_hdr(path.string().c_str(), width, height, 4, data.data());
        }
        else if (ext == ".png" || ext == ".jpg" || ext == ".bmp")
        {
            // Convert float [0,1] to 8-bit [0,255]
            std::vector<uint8_t> data8(data.size());
            for (size_t i = 0; i < data.size(); ++i)
            {
                float val = std::clamp(data[i], 0.0f, 1.0f);
                data8[i] = static_cast<uint8_t>(val * 255.0f + 0.5f);
            }

            if (ext == ".png")
            {
                success = stbi_write_png(path.string().c_str(), width, height, 4,
                    data8.data(), width * 4);
            }
            else if (ext == ".jpg")
            {
                success = stbi_write_jpg(path.string().c_str(), width, height, 4,
                    data8.data(), 95);
            }
            else if (ext == ".bmp")
            {
                success = stbi_write_bmp(path.string().c_str(), width, height, 4,
                    data8.data());
            }
        }

        if (success)
        {
            printf("Saved image: %s (%ux%u)\n", path.string().c_str(), width, height);
        }
        else
        {
            printf("Error: Failed to save image: %s\n", path.string().c_str());
        }
    }

    std::vector<float> VNDFAnalyzer::loadImage(const std::string& filepath,
        uint32_t& width, uint32_t& height)
    {
        std::filesystem::path path(filepath);
        std::string ext = path.extension().string();

        if (ext.empty())
        {
            path += ".hdr";
            ext = ".hdr";
        }

        if (!std::filesystem::exists(path))
        {
            printf("Error: Image file not found: %s\n", path.string().c_str());
            return {};
        }

        std::vector<float> data;
        int w, h, channels;

        if (ext == ".hdr")
        {
            float* pixels = stbi_loadf(path.string().c_str(), &w, &h, &channels, 4);
            if (pixels)
            {
                size_t pixelCount = static_cast<size_t>(w) * h * 4;
                data.assign(pixels, pixels + pixelCount);
                stbi_image_free(pixels);

                width = static_cast<uint32_t>(w);
                height = static_cast<uint32_t>(h);
                printf("Loaded HDR image: %s (%ux%u)\n", path.string().c_str(), width, height);
            }
            else
            {
                printf("Error: Failed to load HDR image: %s\n", path.string().c_str());
            }
        }
        else if (ext == ".png" || ext == ".jpg" || ext == ".bmp" || ext == ".tga")
        {
            unsigned char* pixels = stbi_load(path.string().c_str(), &w, &h, &channels, 4);
            if (pixels)
            {
                size_t pixelCount = static_cast<size_t>(w) * h * 4;
                data.resize(pixelCount);

                for (size_t i = 0; i < pixelCount; ++i)
                {
                    data[i] = static_cast<float>(pixels[i]) / 255.0f;
                }

                stbi_image_free(pixels);

                width = static_cast<uint32_t>(w);
                height = static_cast<uint32_t>(h);
                printf("Loaded LDR image: %s (%ux%u)\n", path.string().c_str(), width, height);
            }
            else
            {
                printf("Error: Failed to load LDR image: %s\n", path.string().c_str());
            }
        }

        return data;
    }

}  // namespace matforge