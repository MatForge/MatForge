/*
 * Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)
 *
 * RMIP Analyzer Implementation
 * Performance analysis for PRI (Psi-guided Ray Intersection) Marching
 */

#include <volk.h>
#include "rmip_analyzer.hpp"
#include <fstream>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <iomanip>
#include <sstream>

// For image I/O
#include <stb_image_write.h>
#include <stb_image.h>

namespace matforge {

    //--------------------------------------------------------------------------------------------------
    // Initialization
    //--------------------------------------------------------------------------------------------------
    void RMIPAnalyzer::init(nvvk::ResourceAllocator& allocator, VkDevice device, VkExtent2D resolution)
    {
        m_allocator = &allocator;
        m_device = device;
        m_resolution = resolution;

        // Create staging buffer for image downloads
        VkDeviceSize bufferSize = resolution.width * resolution.height * 4 * sizeof(float);
        m_allocator->createBuffer(m_stagingBuffer, bufferSize,
            VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VMA_MEMORY_USAGE_GPU_TO_CPU);

        // Create output directory
        std::filesystem::create_directories(m_config.outputDirectory);

        LOGI("RMIP Analyzer initialized: %ux%u\n", resolution.width, resolution.height);
    }

    void RMIPAnalyzer::destroy()
    {
        if (m_allocator && m_stagingBuffer.buffer != VK_NULL_HANDLE)
        {
            m_allocator->destroyBuffer(m_stagingBuffer);
        }

        m_metrics.clear();
        m_capturedFrames.clear();
        m_referenceImage.clear();
    }

    //--------------------------------------------------------------------------------------------------
    // Reference Management
    //--------------------------------------------------------------------------------------------------
    void RMIPAnalyzer::captureReference(VkCommandBuffer cmd, VkImage sourceImage, VkExtent2D extent)
    {
        if (cmd == VK_NULL_HANDLE || sourceImage == VK_NULL_HANDLE)
        {
            LOGE("RMIP Analyzer: Invalid command buffer or image for reference capture\n");
            return;
        }

        // Resize staging buffer if needed
        VkDeviceSize requiredSize = extent.width * extent.height * 4 * sizeof(float);

        // Destroy old buffer if it exists and is wrong size
        if (m_stagingBuffer.buffer != VK_NULL_HANDLE)
        {
            // Check if resize needed (recreate if resolution changed)
            VkDeviceSize currentSize = m_resolution.width * m_resolution.height * 4 * sizeof(float);
            if (currentSize != requiredSize)
            {
                m_allocator->destroyBuffer(m_stagingBuffer);
                m_stagingBuffer = {};
            }
        }

        // Update resolution after size check
        m_resolution = extent;

        // Create buffer if needed
        if (m_stagingBuffer.buffer == VK_NULL_HANDLE)
        {
            m_allocator->createBuffer(m_stagingBuffer, requiredSize,
                VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                VMA_MEMORY_USAGE_GPU_TO_CPU);
        }

        // Transition image to TRANSFER_SRC_OPTIMAL
        VkImageMemoryBarrier barrier{ VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
        barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = sourceImage;
        barrier.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };

        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, nullptr, 0, nullptr, 1, &barrier);

        // Copy image to staging buffer
        VkBufferImageCopy region{};
        region.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        region.imageExtent = { extent.width, extent.height, 1 };

        vkCmdCopyImageToBuffer(cmd, sourceImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            m_stagingBuffer.buffer, 1, &region);

        // Transition back to GENERAL
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;

        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0, 0, nullptr, 0, nullptr, 1, &barrier);

        LOGI("RMIP Analyzer: Reference download recorded (%ux%u) - waiting for GPU sync...\n",
            extent.width, extent.height);
    }

    void RMIPAnalyzer::finalizeReferenceCapture()
    {
        readStagingBuffer(m_referenceImage);
        m_hasReference = true;

        LOGI("RMIP Analyzer: Reference image finalized (%ux%u, %zu floats)\n",
            m_resolution.width, m_resolution.height, m_referenceImage.size());
    }

    void RMIPAnalyzer::loadReference(const std::string& filepath)
    {
        uint32_t width, height;
        m_referenceImage = loadImage(filepath, width, height);

        if (!m_referenceImage.empty())
        {
            m_resolution.width = width;
            m_resolution.height = height;
            m_hasReference = true;
            LOGI("RMIP Analyzer: Loaded reference from %s (%ux%u)\n", filepath.c_str(), width, height);
        }
    }

    void RMIPAnalyzer::saveReference(const std::string& filepath)
    {
        if (m_hasReference && !m_referenceImage.empty())
        {
            saveImage(filepath, m_referenceImage);
            LOGI("RMIP Analyzer: Saved reference to %s\n", filepath.c_str());
        }
    }

    //--------------------------------------------------------------------------------------------------
    // Session Management
    //--------------------------------------------------------------------------------------------------
    void RMIPAnalyzer::startSession(const std::string& sessionName, RMIPMethod method,
                                     int maxTraversalIters, float marchingScale, int maxStackSize)
    {
        if (!m_hasReference)
        {
            LOGE("RMIP Analyzer: Cannot start session without reference image\n");
            return;
        }

        m_sessionActive = true;
        m_sessionName = sessionName;
        m_currentMethod = method;
        m_currentMaxIters = maxTraversalIters;
        m_currentMarchingScale = marchingScale;
        m_currentStackSize = maxStackSize;
        m_sessionStartTime = std::chrono::steady_clock::now();

        LOGI("RMIP Analyzer: Session started: %s (%s, scale=%.1f, maxIters=%d, stack=%d)\n",
            sessionName.c_str(), getMethodName(method).c_str(),
            marchingScale, maxTraversalIters, maxStackSize);
    }

    void RMIPAnalyzer::captureFrame(VkCommandBuffer cmd, VkImage sourceImage,
                                     uint32_t sampleCount, double renderTimeMs)
    {
        if (!m_sessionActive)
        {
            LOGE("RMIP Analyzer: No active session for frame capture\n");
            return;
        }

        if (cmd == VK_NULL_HANDLE || sourceImage == VK_NULL_HANDLE)
        {
            LOGE("RMIP Analyzer: Invalid command buffer or image for frame capture\n");
            return;
        }

        // Transition image to TRANSFER_SRC_OPTIMAL
        VkImageMemoryBarrier barrier{ VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
        barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = sourceImage;
        barrier.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };

        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, nullptr, 0, nullptr, 1, &barrier);

        // Copy image to staging buffer
        VkBufferImageCopy region{};
        region.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        region.imageExtent = { m_resolution.width, m_resolution.height, 1 };

        vkCmdCopyImageToBuffer(cmd, sourceImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            m_stagingBuffer.buffer, 1, &region);

        // Transition back to GENERAL
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;

        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0, 0, nullptr, 0, nullptr, 1, &barrier);

        m_pendingSampleCount = sampleCount;
        m_pendingRenderTimeMs = renderTimeMs;
    }

    void RMIPAnalyzer::finalizeFrameCapture()
    {
        if (!m_sessionActive)
        {
            LOGE("RMIP Analyzer: No active session for frame finalization\n");
            return;
        }

        std::vector<float> frameData;
        readStagingBuffer(frameData);

        // Compute metrics
        RMIPMetrics metrics;
        metrics.method = m_currentMethod;
        metrics.sampleCount = m_pendingSampleCount;
        metrics.maxTraversalIters = m_currentMaxIters;
        metrics.marchingScale = m_currentMarchingScale;
        metrics.maxStackSize = m_currentStackSize;
        metrics.renderTimeMs = m_pendingRenderTimeMs;

        // Compare against reference
        if (m_hasReference && !m_referenceImage.empty())
        {
            metrics.mse = computeMSE(frameData, m_referenceImage, m_resolution.width, m_resolution.height);
            metrics.rmse = computeRMSE(metrics.mse);
            metrics.psnr = computePSNR(metrics.mse);
            metrics.ssim = computeSSIM(frameData, m_referenceImage, m_resolution.width, m_resolution.height);
            metrics.holePercentage = computeHolePercentage(frameData, m_referenceImage,
                m_resolution.width, m_resolution.height, 0.1f);
            metrics.hasHoles = metrics.holePercentage > 1.0;  // More than 1% holes
        }

        m_metrics.push_back(metrics);

        // Store captured frame
        CapturedFrame frame;
        frame.method = m_currentMethod;
        frame.marchingScale = m_currentMarchingScale;
        frame.maxIters = m_currentMaxIters;
        frame.sampleCount = m_pendingSampleCount;
        frame.data = std::move(frameData);
        m_capturedFrames.push_back(std::move(frame));

        LOGI("RMIP Analyzer: Frame captured - MSE: %.6f, PSNR: %.2f dB, Holes: %.2f%%, Time: %.2f ms\n",
            metrics.mse, metrics.psnr, metrics.holePercentage, metrics.renderTimeMs);
    }

    void RMIPAnalyzer::endSession()
    {
        m_sessionActive = false;

        auto duration = std::chrono::steady_clock::now() - m_sessionStartTime;
        auto seconds = std::chrono::duration_cast<std::chrono::seconds>(duration).count();

        LOGI("RMIP Analyzer: Session ended '%s' (%lld seconds, %zu captures)\n",
            m_sessionName.c_str(), (long long)seconds, m_metrics.size());
    }

    void RMIPAnalyzer::clearMetrics()
    {
        m_metrics.clear();
        m_capturedFrames.clear();
        LOGI("RMIP Analyzer: Metrics cleared\n");
    }

    //--------------------------------------------------------------------------------------------------
    // Metrics Computation
    //--------------------------------------------------------------------------------------------------
    double RMIPAnalyzer::computeMSE(const std::vector<float>& test, const std::vector<float>& ref,
                                     uint32_t width, uint32_t height)
    {
        if (test.size() != ref.size() || test.empty())
            return 0.0;

        double sumSquaredError = 0.0;
        size_t pixelCount = width * height;

        for (size_t i = 0; i < pixelCount * 4; i += 4)  // RGBA
        {
            for (int c = 0; c < 3; ++c)  // RGB only
            {
                double diff = test[i + c] - ref[i + c];
                sumSquaredError += diff * diff;
            }
        }

        return sumSquaredError / (pixelCount * 3.0);
    }

    double RMIPAnalyzer::computeRMSE(double mse)
    {
        return std::sqrt(mse);
    }

    double RMIPAnalyzer::computePSNR(double mse)
    {
        if (mse < 1e-10)
            return 100.0;  // Perfect match

        return 10.0 * std::log10(1.0 / mse);
    }

    double RMIPAnalyzer::computeSSIM(const std::vector<float>& test, const std::vector<float>& ref,
                                      uint32_t width, uint32_t height)
    {
        if (test.size() != ref.size() || test.empty())
            return 0.0;

        const float C1 = 0.01f * 0.01f;
        const float C2 = 0.03f * 0.03f;

        double meanTest = 0.0, meanRef = 0.0;
        size_t pixelCount = width * height;

        // Compute means (luminance)
        for (size_t i = 0; i < pixelCount * 4; i += 4)
        {
            float testLuma = 0.2126f * test[i] + 0.7152f * test[i + 1] + 0.0722f * test[i + 2];
            float refLuma = 0.2126f * ref[i] + 0.7152f * ref[i + 1] + 0.0722f * ref[i + 2];
            meanTest += testLuma;
            meanRef += refLuma;
        }
        meanTest /= pixelCount;
        meanRef /= pixelCount;

        // Compute variances and covariance
        double varTest = 0.0, varRef = 0.0, covar = 0.0;
        for (size_t i = 0; i < pixelCount * 4; i += 4)
        {
            float testLuma = 0.2126f * test[i] + 0.7152f * test[i + 1] + 0.0722f * test[i + 2];
            float refLuma = 0.2126f * ref[i] + 0.7152f * ref[i + 1] + 0.0722f * ref[i + 2];

            double diffTest = testLuma - meanTest;
            double diffRef = refLuma - meanRef;

            varTest += diffTest * diffTest;
            varRef += diffRef * diffRef;
            covar += diffTest * diffRef;
        }
        varTest /= pixelCount;
        varRef /= pixelCount;
        covar /= pixelCount;

        // SSIM formula
        double numerator = (2.0 * meanTest * meanRef + C1) * (2.0 * covar + C2);
        double denominator = (meanTest * meanTest + meanRef * meanRef + C1) * (varTest + varRef + C2);

        return numerator / denominator;
    }

    double RMIPAnalyzer::computeHolePercentage(const std::vector<float>& test, const std::vector<float>& ref,
                                                uint32_t width, uint32_t height, float threshold)
    {
        if (test.size() != ref.size() || test.empty())
            return 0.0;

        size_t pixelCount = width * height;
        size_t holeCount = 0;

        for (size_t i = 0; i < pixelCount * 4; i += 4)
        {
            // Compare luminance - if test is significantly darker than reference, it's a hole
            float testLuma = 0.2126f * test[i] + 0.7152f * test[i + 1] + 0.0722f * test[i + 2];
            float refLuma = 0.2126f * ref[i] + 0.7152f * ref[i + 1] + 0.0722f * ref[i + 2];

            // Check if reference has significant brightness and test is much darker
            if (refLuma > 0.01f && (refLuma - testLuma) > threshold * refLuma)
            {
                holeCount++;
            }
        }

        return 100.0 * static_cast<double>(holeCount) / static_cast<double>(pixelCount);
    }

    //--------------------------------------------------------------------------------------------------
    // Results Access
    //--------------------------------------------------------------------------------------------------
    RMIPMetrics* RMIPAnalyzer::getMetrics(RMIPMethod method, float marchingScale, int maxIters)
    {
        for (auto& m : m_metrics)
        {
            if (m.method == method &&
                std::abs(m.marchingScale - marchingScale) < 0.01f &&
                m.maxTraversalIters == maxIters)
            {
                return &m;
            }
        }
        return nullptr;
    }

    std::string RMIPAnalyzer::getMethodName(RMIPMethod method)
    {
        switch (method)
        {
        case RMIPMethod::BruteForce:  return "BruteForce";
        case RMIPMethod::PsiMarching: return "PsiMarching";
        default:                      return "Unknown";
        }
    }

    //--------------------------------------------------------------------------------------------------
    // Export Functions
    //--------------------------------------------------------------------------------------------------
    void RMIPAnalyzer::exportMetricsCSV(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("RMIP Analyzer: Failed to open CSV file: %s\n", filepath.c_str());
            return;
        }

        // Header
        file << "Method,SampleCount,MaxTraversalIters,MarchingScale,MaxStackSize,"
             << "MSE,RMSE,PSNR,SSIM,HolePercentage,RenderTimeMs,HasHoles,Notes\n";

        // Data
        for (const auto& m : m_metrics)
        {
            file << getMethodName(m.method) << ","
                 << m.sampleCount << ","
                 << m.maxTraversalIters << ","
                 << std::fixed << std::setprecision(2) << m.marchingScale << ","
                 << m.maxStackSize << ","
                 << std::scientific << std::setprecision(8) << m.mse << ","
                 << std::scientific << std::setprecision(8) << m.rmse << ","
                 << std::fixed << std::setprecision(3) << m.psnr << ","
                 << std::fixed << std::setprecision(4) << m.ssim << ","
                 << std::fixed << std::setprecision(4) << m.holePercentage << ","
                 << std::fixed << std::setprecision(2) << m.renderTimeMs << ","
                 << (m.hasHoles ? "true" : "false") << ","
                 << "\"" << m.notes << "\"\n";
        }

        file.close();
        LOGI("RMIP Analyzer: Exported metrics to: %s\n", filepath.c_str());
    }

    void RMIPAnalyzer::exportMetricsCSV(const std::string& filepath, RMIPMethod method)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("RMIP Analyzer: Failed to open CSV file: %s\n", filepath.c_str());
            return;
        }

        // Header
        file << "Method,SampleCount,MaxTraversalIters,MarchingScale,MaxStackSize,"
             << "MSE,RMSE,PSNR,SSIM,HolePercentage,RenderTimeMs,HasHoles,Notes\n";

        // Data - only export metrics matching the specified method
        for (const auto& m : m_metrics)
        {
            if (m.method != method)
                continue;

            file << getMethodName(m.method) << ","
                 << m.sampleCount << ","
                 << m.maxTraversalIters << ","
                 << std::fixed << std::setprecision(2) << m.marchingScale << ","
                 << m.maxStackSize << ","
                 << std::scientific << std::setprecision(8) << m.mse << ","
                 << std::scientific << std::setprecision(8) << m.rmse << ","
                 << std::fixed << std::setprecision(3) << m.psnr << ","
                 << std::fixed << std::setprecision(4) << m.ssim << ","
                 << std::fixed << std::setprecision(4) << m.holePercentage << ","
                 << std::fixed << std::setprecision(2) << m.renderTimeMs << ","
                 << (m.hasHoles ? "true" : "false") << ","
                 << "\"" << m.notes << "\"\n";
        }

        file.close();
        LOGI("RMIP Analyzer: Exported %s metrics to: %s\n", getMethodName(method).c_str(), filepath.c_str());
    }

    void RMIPAnalyzer::exportPerformanceCSV(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("RMIP Analyzer: Failed to open CSV file: %s\n", filepath.c_str());
            return;
        }

        // Header - performance by marching scale
        file << "MarchingScale,BruteForce_TimeMs,PsiMarching_TimeMs,Speedup\n";

        // Collect unique marching scales
        std::vector<float> scales;
        for (const auto& m : m_metrics)
        {
            bool found = false;
            for (float s : scales)
            {
                if (std::abs(s - m.marchingScale) < 0.01f)
                {
                    found = true;
                    break;
                }
            }
            if (!found)
                scales.push_back(m.marchingScale);
        }
        std::sort(scales.begin(), scales.end());

        for (float scale : scales)
        {
            double bruteTime = 0.0, psiTime = 0.0;
            int bruteCount = 0, psiCount = 0;

            for (const auto& m : m_metrics)
            {
                if (std::abs(m.marchingScale - scale) < 0.01f)
                {
                    if (m.method == RMIPMethod::BruteForce)
                    {
                        bruteTime += m.renderTimeMs;
                        bruteCount++;
                    }
                    else
                    {
                        psiTime += m.renderTimeMs;
                        psiCount++;
                    }
                }
            }

            if (bruteCount > 0) bruteTime /= bruteCount;
            if (psiCount > 0) psiTime /= psiCount;

            double speedup = (psiTime > 0) ? bruteTime / psiTime : 0.0;

            file << std::fixed << std::setprecision(2) << scale << ","
                 << std::fixed << std::setprecision(2) << bruteTime << ","
                 << std::fixed << std::setprecision(2) << psiTime << ","
                 << std::fixed << std::setprecision(2) << speedup << "\n";
        }

        file.close();
        LOGI("RMIP Analyzer: Exported performance to: %s\n", filepath.c_str());
    }

    void RMIPAnalyzer::exportQualityCSV(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("RMIP Analyzer: Failed to open CSV file: %s\n", filepath.c_str());
            return;
        }

        // Header - quality by sample count
        file << "SampleCount,BruteForce_PSNR,PsiMarching_PSNR,BruteForce_SSIM,PsiMarching_SSIM\n";

        // Collect unique sample counts
        std::vector<uint32_t> sampleCounts;
        for (const auto& m : m_metrics)
        {
            if (std::find(sampleCounts.begin(), sampleCounts.end(), m.sampleCount) == sampleCounts.end())
                sampleCounts.push_back(m.sampleCount);
        }
        std::sort(sampleCounts.begin(), sampleCounts.end());

        for (uint32_t spp : sampleCounts)
        {
            double brutePSNR = 0.0, psiPSNR = 0.0;
            double bruteSSIM = 0.0, psiSSIM = 0.0;
            int bruteCount = 0, psiCount = 0;

            for (const auto& m : m_metrics)
            {
                if (m.sampleCount == spp)
                {
                    if (m.method == RMIPMethod::BruteForce)
                    {
                        brutePSNR += m.psnr;
                        bruteSSIM += m.ssim;
                        bruteCount++;
                    }
                    else
                    {
                        psiPSNR += m.psnr;
                        psiSSIM += m.ssim;
                        psiCount++;
                    }
                }
            }

            if (bruteCount > 0) { brutePSNR /= bruteCount; bruteSSIM /= bruteCount; }
            if (psiCount > 0) { psiPSNR /= psiCount; psiSSIM /= psiCount; }

            file << spp << ","
                 << std::fixed << std::setprecision(3) << brutePSNR << ","
                 << std::fixed << std::setprecision(3) << psiPSNR << ","
                 << std::fixed << std::setprecision(4) << bruteSSIM << ","
                 << std::fixed << std::setprecision(4) << psiSSIM << "\n";
        }

        file.close();
        LOGI("RMIP Analyzer: Exported quality to: %s\n", filepath.c_str());
    }

    void RMIPAnalyzer::exportHoleAnalysisCSV(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("RMIP Analyzer: Failed to open CSV file: %s\n", filepath.c_str());
            return;
        }

        // Header
        file << "Method,MarchingScale,MaxTraversalIters,SampleCount,HolePercentage\n";

        for (const auto& m : m_metrics)
        {
            file << getMethodName(m.method) << ","
                 << std::fixed << std::setprecision(2) << m.marchingScale << ","
                 << m.maxTraversalIters << ","
                 << m.sampleCount << ","
                 << std::fixed << std::setprecision(4) << m.holePercentage << "\n";
        }

        file.close();
        LOGI("RMIP Analyzer: Exported hole analysis to: %s\n", filepath.c_str());
    }

    void RMIPAnalyzer::exportComparisonImages(const std::string& directory)
    {
        std::filesystem::create_directories(directory);

        for (const auto& frame : m_capturedFrames)
        {
            std::stringstream ss;
            ss << directory << "/"
               << getMethodName(frame.method) << "_"
               << "scale" << std::fixed << std::setprecision(1) << frame.marchingScale << "_"
               << "iters" << frame.maxIters << "_"
               << "spp" << frame.sampleCount
               << ".png";

            saveImage(ss.str(), frame.data);
        }

        LOGI("RMIP Analyzer: Exported %zu comparison images to: %s\n",
            m_capturedFrames.size(), directory.c_str());
    }

    void RMIPAnalyzer::exportErrorMap(const std::string& filepath, const std::vector<float>& testImage)
    {
        if (!m_hasReference || testImage.size() != m_referenceImage.size())
        {
            LOGE("RMIP Analyzer: Cannot generate error map without matching reference\n");
            return;
        }

        auto errorData = generateErrorMap(testImage, m_referenceImage,
            m_resolution.width, m_resolution.height, 0.1f);

        if (!errorData.empty())
        {
            stbi_write_png(filepath.c_str(), m_resolution.width, m_resolution.height,
                3, errorData.data(), m_resolution.width * 3);
            LOGI("RMIP Analyzer: Exported error map to: %s\n", filepath.c_str());
        }
    }

    void RMIPAnalyzer::generatePlotScript(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("RMIP Analyzer: Failed to create plot script: %s\n", filepath.c_str());
            return;
        }

        file << R"(#!/usr/bin/env python3
"""
RMIP (PRI Marching) Analysis Plotting Script
Auto-generated by RMIPAnalyzer

Compares Brute Force vs Psi-guided texel marching for displacement mapping.

Usage: python plot_rmip_results.py
"""

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path

# Load data
metrics_df = pd.read_csv('rmip_metrics.csv')
performance_df = pd.read_csv('rmip_performance.csv')
quality_df = pd.read_csv('rmip_quality.csv')
holes_df = pd.read_csv('rmip_holes.csv')

# Set up figure style
plt.style.use('seaborn-v0_8-whitegrid')
fig_size = (12, 8)

# Figure 1: PSNR vs Sample Count
plt.figure(figsize=fig_size)
for method in metrics_df['Method'].unique():
    method_data = metrics_df[metrics_df['Method'] == method]
    plt.semilogx(method_data['SampleCount'], method_data['PSNR'],
                 marker='o', label=method, linewidth=2, markersize=8)
plt.xlabel('Samples per Pixel', fontsize=12)
plt.ylabel('PSNR (dB)', fontsize=12)
plt.title('RMIP: Quality vs Sample Count', fontsize=14)
plt.legend(fontsize=10)
plt.grid(True, alpha=0.3)
plt.savefig('rmip_psnr_vs_spp.png', dpi=300, bbox_inches='tight')
print("Saved: rmip_psnr_vs_spp.png")

# Figure 2: Render Time Comparison
plt.figure(figsize=fig_size)
x = np.arange(len(performance_df['MarchingScale']))
width = 0.35
plt.bar(x - width/2, performance_df['BruteForce_TimeMs'], width, label='Brute Force', alpha=0.8)
plt.bar(x + width/2, performance_df['PsiMarching_TimeMs'], width, label='Psi Marching', alpha=0.8)
plt.xlabel('Marching Scale (texels)', fontsize=12)
plt.ylabel('Render Time (ms)', fontsize=12)
plt.title('RMIP: Performance Comparison', fontsize=14)
plt.xticks(x, performance_df['MarchingScale'])
plt.legend(fontsize=10)
plt.grid(True, alpha=0.3, axis='y')
plt.savefig('rmip_performance.png', dpi=300, bbox_inches='tight')
print("Saved: rmip_performance.png")

# Figure 3: Hole Percentage Analysis
plt.figure(figsize=fig_size)
psi_data = holes_df[holes_df['Method'] == 'PsiMarching']
if not psi_data.empty:
    for scale in psi_data['MarchingScale'].unique():
        scale_data = psi_data[psi_data['MarchingScale'] == scale]
        plt.semilogx(scale_data['SampleCount'], scale_data['HolePercentage'],
                     marker='s', label=f'Scale={scale}', linewidth=2)
    plt.xlabel('Samples per Pixel', fontsize=12)
    plt.ylabel('Hole Percentage (%)', fontsize=12)
    plt.title('Psi Marching: Stripping Artifacts vs Sample Count', fontsize=14)
    plt.legend(fontsize=10)
    plt.grid(True, alpha=0.3)
    plt.savefig('rmip_holes.png', dpi=300, bbox_inches='tight')
    print("Saved: rmip_holes.png")

# Figure 4: Quality vs Performance Trade-off
plt.figure(figsize=fig_size)
for method in metrics_df['Method'].unique():
    method_data = metrics_df[metrics_df['Method'] == method]
    plt.scatter(method_data['RenderTimeMs'], method_data['PSNR'],
                s=100, alpha=0.7, label=method)
plt.xlabel('Render Time (ms)', fontsize=12)
plt.ylabel('PSNR (dB)', fontsize=12)
plt.title('RMIP: Quality vs Performance Trade-off', fontsize=14)
plt.legend(fontsize=10)
plt.grid(True, alpha=0.3)
plt.savefig('rmip_tradeoff.png', dpi=300, bbox_inches='tight')
print("Saved: rmip_tradeoff.png")

# Summary statistics
print("\n=== RMIP Analysis Summary ===")
for method in metrics_df['Method'].unique():
    method_data = metrics_df[metrics_df['Method'] == method]
    print(f"\n{method}:")
    print(f"  Avg PSNR: {method_data['PSNR'].mean():.2f} dB")
    print(f"  Avg SSIM: {method_data['SSIM'].mean():.4f}")
    print(f"  Avg Time: {method_data['RenderTimeMs'].mean():.2f} ms")
    print(f"  Avg Holes: {method_data['HolePercentage'].mean():.2f}%")

print("\n=== Plots generated successfully ===")
)";

        file.close();
        LOGI("RMIP Analyzer: Generated plot script: %s\n", filepath.c_str());
    }

    //--------------------------------------------------------------------------------------------------
    // Helper Functions
    //--------------------------------------------------------------------------------------------------
    void RMIPAnalyzer::readStagingBuffer(std::vector<float>& outData)
    {
        size_t pixelCount = m_resolution.width * m_resolution.height;
        outData.resize(pixelCount * 4);

        void* mapped = nullptr;
        VkResult result = vmaMapMemory(*m_allocator, m_stagingBuffer.allocation, &mapped);
        if (result == VK_SUCCESS && mapped != nullptr)
        {
            std::memcpy(outData.data(), mapped, outData.size() * sizeof(float));
            vmaUnmapMemory(*m_allocator, m_stagingBuffer.allocation);
        }
        else
        {
            LOGE("RMIP Analyzer: Failed to map staging buffer for reading\n");
        }
    }

    void RMIPAnalyzer::saveImage(const std::string& filepath, const std::vector<float>& data)
    {
        if (data.empty())
        {
            LOGE("RMIP Analyzer: Cannot save empty image data\n");
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
            success = stbi_write_hdr(path.string().c_str(), m_resolution.width,
                m_resolution.height, 4, data.data());
        }
        else if (ext == ".png" || ext == ".jpg" || ext == ".bmp")
        {
            // Convert float [0,1] to 8-bit [0,255]
            std::vector<uint8_t> ldrData(data.size());
            for (size_t i = 0; i < data.size(); ++i)
            {
                float val = std::clamp(data[i], 0.0f, 1.0f);
                ldrData[i] = static_cast<uint8_t>(val * 255.0f + 0.5f);
            }

            if (ext == ".png")
            {
                success = stbi_write_png(path.string().c_str(), m_resolution.width,
                    m_resolution.height, 4, ldrData.data(), m_resolution.width * 4);
            }
            else if (ext == ".jpg")
            {
                success = stbi_write_jpg(path.string().c_str(), m_resolution.width,
                    m_resolution.height, 4, ldrData.data(), 95);
            }
            else if (ext == ".bmp")
            {
                success = stbi_write_bmp(path.string().c_str(), m_resolution.width,
                    m_resolution.height, 4, ldrData.data());
            }
        }

        if (success)
        {
            LOGI("RMIP Analyzer: Saved image: %s (%ux%u)\n", path.string().c_str(),
                m_resolution.width, m_resolution.height);
        }
        else
        {
            LOGE("RMIP Analyzer: Failed to save image: %s\n", path.string().c_str());
        }
    }

    std::vector<float> RMIPAnalyzer::loadImage(const std::string& filepath, uint32_t& width, uint32_t& height)
    {
        int w, h, channels;
        float* imageData = stbi_loadf(filepath.c_str(), &w, &h, &channels, 4);

        if (!imageData)
        {
            LOGE("RMIP Analyzer: Failed to load image: %s\n", filepath.c_str());
            return {};
        }

        width = w;
        height = h;

        std::vector<float> data(w * h * 4);
        std::memcpy(data.data(), imageData, data.size() * sizeof(float));

        stbi_image_free(imageData);

        return data;
    }

    std::vector<uint8_t> RMIPAnalyzer::generateErrorMap(const std::vector<float>& testImage,
                                                         const std::vector<float>& refImage,
                                                         uint32_t width, uint32_t height, float maxError)
    {
        if (testImage.size() != refImage.size())
            return {};

        std::vector<uint8_t> errorMap(width * height * 3);

        for (size_t i = 0; i < width * height; ++i)
        {
            size_t srcIdx = i * 4;
            size_t dstIdx = i * 3;

            // Compute per-pixel error (luminance difference)
            float testLuma = 0.2126f * testImage[srcIdx] + 0.7152f * testImage[srcIdx + 1] + 0.0722f * testImage[srcIdx + 2];
            float refLuma = 0.2126f * refImage[srcIdx] + 0.7152f * refImage[srcIdx + 1] + 0.0722f * refImage[srcIdx + 2];

            float error = std::abs(testLuma - refLuma);
            float normalizedError = std::clamp(error / maxError, 0.0f, 1.0f);

            // Color map: blue (low error) -> red (high error)
            // Also highlight holes (test much darker than ref) in magenta
            bool isHole = (refLuma > 0.01f && (refLuma - testLuma) > 0.1f * refLuma);

            if (isHole)
            {
                // Magenta for holes
                errorMap[dstIdx + 0] = 255;
                errorMap[dstIdx + 1] = 0;
                errorMap[dstIdx + 2] = 255;
            }
            else
            {
                // Blue-to-red gradient for error magnitude
                errorMap[dstIdx + 0] = static_cast<uint8_t>(normalizedError * 255);
                errorMap[dstIdx + 1] = static_cast<uint8_t>((1.0f - normalizedError) * 128);
                errorMap[dstIdx + 2] = static_cast<uint8_t>((1.0f - normalizedError) * 255);
            }
        }

        return errorMap;
    }

}  // namespace matforge
