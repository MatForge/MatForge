/*
 * Copyright (c) 2025, MatForge Team (CIS 5650, University of Pennsylvania)
 *
 * MSX Analyzer Implementation
 */

#include <volk.h>
#include "msx_analyzer.hpp"
#include <fstream>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>

 // For image I/O (you may need to adjust based on your project)
#include <stb_image_write.h>
#include <stb_image.h>

namespace matforge {

    //--------------------------------------------------------------------------------------------------
    // Initialization
    //--------------------------------------------------------------------------------------------------
    void MSXAnalyzer::init(nvvk::ResourceAllocator& allocator, VkDevice device, const MSXTestConfig& config)
    {
        m_allocator = &allocator;
        m_device = device;
        m_config = config;

        // Calculate total number of tests
        m_totalTests = config.roughnessValues.size() * config.materials.size() * config.methods.size();
        if (config.runFurnaceTest)
        {
            m_totalTests += config.roughnessValues.size() * config.methods.size();  // Furnace tests
        }

        // Create staging buffer for image downloads
        VkDeviceSize bufferSize = config.resolution.width * config.resolution.height * 4 * sizeof(float);
        m_allocator->createBuffer(m_stagingBuffer, bufferSize,
            VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VMA_MEMORY_USAGE_GPU_TO_CPU);

        // Create output directory
        std::filesystem::create_directories(config.outputDirectory);

        LOGI("MSX Analyzer initialized: %zu total tests\n", m_totalTests);
    }

    void MSXAnalyzer::destroy()
    {
        if (m_allocator && m_stagingBuffer.buffer != VK_NULL_HANDLE)
        {
            m_allocator->destroyBuffer(m_stagingBuffer);
        }

        m_metrics.clear();
        m_capturedFrames.clear();
        m_referenceImages.clear();
    }

    //--------------------------------------------------------------------------------------------------
    // Reference Management (Async pattern like VNDFAnalyzer)
    //--------------------------------------------------------------------------------------------------
    void MSXAnalyzer::captureReference(VkCommandBuffer cmd, VkImage sourceImage, VkExtent2D extent)
    {
        if (cmd == VK_NULL_HANDLE || sourceImage == VK_NULL_HANDLE)
        {
            LOGE("MSX Analyzer: Invalid command buffer or image for reference capture\n");
            return;
        }

        m_resolution = extent;

        // Resize staging buffer if needed
        VkDeviceSize requiredSize = extent.width * extent.height * 4 * sizeof(float);

        // Destroy old buffer if it exists and is wrong size
        if (m_stagingBuffer.buffer != VK_NULL_HANDLE)
        {
            // Check if resize needed (recreate if resolution changed)
            VkDeviceSize currentSize = m_config.resolution.width * m_config.resolution.height * 4 * sizeof(float);
            if (currentSize != requiredSize)
            {
                m_allocator->destroyBuffer(m_stagingBuffer);
                m_stagingBuffer = {};
            }
        }

        // Create buffer if needed
        if (m_stagingBuffer.buffer == VK_NULL_HANDLE)
        {
            m_allocator->createBuffer(m_stagingBuffer, requiredSize,
                VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                VMA_MEMORY_USAGE_GPU_TO_CPU);
            // Update config resolution to match
            m_config.resolution = extent;
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

        LOGI("MSX Analyzer: Reference download recorded (%ux%u) - waiting for GPU sync...\n",
            extent.width, extent.height);
    }

    void MSXAnalyzer::finalizeReferenceCapture()
    {
        // Read from staging buffer
        readStagingBuffer(m_referenceImage);
        m_hasReference = true;

        LOGI("MSX Analyzer: Reference image finalized (%ux%u, %zu floats)\n",
            m_resolution.width, m_resolution.height, m_referenceImage.size());
    }

    //--------------------------------------------------------------------------------------------------
    // Async Session Management
    //--------------------------------------------------------------------------------------------------
    void MSXAnalyzer::startSession(const std::string& sessionName, MSXMethod method,
        TestMaterial material, float roughness)
    {
        if (!m_hasReference)
        {
            LOGE("MSX Analyzer: Cannot start session without reference image\n");
            return;
        }

        m_sessionActive = true;
        m_sessionName = sessionName;
        m_currentMethod = method;
        m_currentMaterial = material;
        m_currentRoughness = roughness;
        m_sessionStartTime = std::chrono::steady_clock::now();

        LOGI("MSX Analyzer: Session started: %s (%s, %s, α=%.2f)\n",
            sessionName.c_str(), getMethodName(method).c_str(),
            getMaterialName(material).c_str(), roughness);
    }

    void MSXAnalyzer::captureFrame(VkCommandBuffer cmd, VkImage sourceImage,
        uint32_t sampleCount, double renderTimeMs)
    {
        if (!m_sessionActive)
        {
            LOGE("MSX Analyzer: No active session for frame capture\n");
            return;
        }

        if (cmd == VK_NULL_HANDLE || sourceImage == VK_NULL_HANDLE)
        {
            LOGE("MSX Analyzer: Invalid command buffer or image for frame capture\n");
            return;
        }

        // Record GPU image download
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

        VkBufferImageCopy region{};
        region.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        region.imageExtent = { m_resolution.width, m_resolution.height, 1 };

        vkCmdCopyImageToBuffer(cmd, sourceImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            m_stagingBuffer.buffer, 1, &region);

        barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;

        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0, 0, nullptr, 0, nullptr, 1, &barrier);

        // Store pending capture info
        m_pendingSampleCount = sampleCount;
        m_pendingRenderTimeMs = renderTimeMs;
    }

    void MSXAnalyzer::finalizeFrameCapture()
    {
        if (!m_sessionActive)
        {
            LOGE("MSX Analyzer: No active session for frame finalization\n");
            return;
        }

        // Read from staging buffer
        std::vector<float> frameData;
        readStagingBuffer(frameData);

        // Compute metrics
        MSXMetrics metrics;
        metrics.method = m_currentMethod;
        metrics.material = m_currentMaterial;
        metrics.roughness = m_currentRoughness;
        metrics.sampleCount = m_pendingSampleCount;
        metrics.renderTimeMs = m_pendingRenderTimeMs;

        // Compare against reference
        if (m_hasReference && !m_referenceImage.empty())
        {
            metrics.mse = computeMSE(frameData, m_referenceImage, m_resolution.width, m_resolution.height);
            metrics.psnr = computePSNR(metrics.mse);
            metrics.ssim = computeSSIM(frameData, m_referenceImage, m_resolution.width, m_resolution.height);
        }

        // Energy metrics
        metrics.energyLoss = computeEnergyLoss(frameData, m_resolution.width, m_resolution.height);
        metrics.hasSpecularPeak = detectSpecularArtifacts(frameData, m_resolution.width,
            m_resolution.height, m_currentRoughness);
        metrics.isTooDark = (metrics.energyLoss > 0.15);

        m_metrics.push_back(metrics);

        // Store captured frame
        CapturedFrame frame;
        frame.method = m_currentMethod;
        frame.material = m_currentMaterial;
        frame.roughness = m_currentRoughness;
        frame.data = std::move(frameData);
        m_capturedFrames.push_back(std::move(frame));

        LOGI("MSX Analyzer: Frame captured - MSE: %.6f, PSNR: %.2f dB, Time: %.2f ms\n",
            metrics.mse, metrics.psnr, metrics.renderTimeMs);
    }

    void MSXAnalyzer::endSession()
    {
        m_sessionActive = false;
        m_testComplete = true;

        auto duration = std::chrono::steady_clock::now() - m_sessionStartTime;
        auto seconds = std::chrono::duration_cast<std::chrono::seconds>(duration).count();

        LOGI("MSX Analyzer: Session ended '%s' (%lld seconds, %zu captures)\n",
            m_sessionName.c_str(), (long long)seconds, m_metrics.size());
    }

    void MSXAnalyzer::loadReferenceSet(const std::string& directory)
    {
        LOGI("Loading reference set from: %s\n", directory.c_str());

        m_referenceImages.clear();

        for (const auto& material : m_config.materials)
        {
            for (float roughness : m_config.roughnessValues)
            {
                std::string filename = directory + "/" + getMaterialName(material) +
                    "_alpha" + std::to_string(static_cast<int>(roughness * 100)) + ".hdr";

                if (std::filesystem::exists(filename))
                {
                    uint32_t width, height;
                    auto data = loadImage(filename, width, height);

                    if (!data.empty())
                    {
                        std::string key = getReferenceKey(material, roughness);
                        m_referenceImages[key] = std::move(data);
                        LOGI("  Loaded: %s\n", filename.c_str());
                    }
                }
            }
        }

        m_hasReferences = !m_referenceImages.empty();
        LOGI("Loaded %zu reference images\n", m_referenceImages.size());
    }

    void MSXAnalyzer::saveReferenceSet(const std::string& directory)
    {
        std::filesystem::create_directories(directory);

        for (const auto& [key, data] : m_referenceImages)
        {
            std::string filename = directory + "/" + key + ".hdr";
            saveImage(filename, data);
            LOGI("Saved reference: %s\n", filename.c_str());
        }
    }

    //--------------------------------------------------------------------------------------------------
    // Metrics Computation
    //--------------------------------------------------------------------------------------------------
    double MSXAnalyzer::computeMSE(const std::vector<float>& test, const std::vector<float>& ref,
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

    double MSXAnalyzer::computePSNR(double mse)
    {
        if (mse < 1e-10)
            return 100.0;  // Perfect match

        return 10.0 * std::log10(1.0 / mse);
    }

    double MSXAnalyzer::computeSSIM(const std::vector<float>& test, const std::vector<float>& ref,
        uint32_t width, uint32_t height)
    {
        // Simplified SSIM implementation
        // For production, use a proper SSIM library

        if (test.size() != ref.size() || test.empty())
            return 0.0;

        const float C1 = 0.01f * 0.01f;
        const float C2 = 0.03f * 0.03f;

        double meanTest = 0.0, meanRef = 0.0;
        size_t pixelCount = width * height;

        // Compute means
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

    double MSXAnalyzer::computeEnergyLoss(const std::vector<float>& image, uint32_t width, uint32_t height)
    {
        double totalEnergy = 0.0;
        size_t pixelCount = width * height;

        for (size_t i = 0; i < pixelCount * 4; i += 4)
        {
            // Luminance
            float luma = 0.2126f * image[i] + 0.7152f * image[i + 1] + 0.0722f * image[i + 2];
            totalEnergy += luma;
        }

        double avgEnergy = totalEnergy / pixelCount;
        double expectedEnergy = 1.0;  // Assumes normalized input

        return std::max(0.0, expectedEnergy - avgEnergy);
    }

    double MSXAnalyzer::computeFurnaceTestError(const std::vector<float>& image, uint32_t width, uint32_t height)
    {
        // In furnace test, all pixels should be 1.0
        double sumError = 0.0;
        size_t pixelCount = width * height;

        for (size_t i = 0; i < pixelCount * 4; i += 4)
        {
            for (int c = 0; c < 3; ++c)
            {
                double error = std::abs(image[i + c] - 1.0f);
                sumError += error;
            }
        }

        return sumError / (pixelCount * 3.0);
    }

    bool MSXAnalyzer::detectSpecularArtifacts(const std::vector<float>& image, uint32_t width,
        uint32_t height, float roughness)
    {
        // For high roughness (> 0.6), we shouldn't see sharp specular peaks
        if (roughness < 0.6f)
            return false;

        // Find peak brightness
        float maxBrightness = 0.0f;
        float avgBrightness = 0.0f;
        size_t pixelCount = width * height;

        for (size_t i = 0; i < pixelCount * 4; i += 4)
        {
            float luma = 0.2126f * image[i] + 0.7152f * image[i + 1] + 0.0722f * image[i + 2];
            maxBrightness = std::max(maxBrightness, luma);
            avgBrightness += luma;
        }
        avgBrightness /= pixelCount;

        // If peak is more than 5x average, likely an artifact
        float ratio = maxBrightness / (avgBrightness + 0.001f);
        return ratio > 5.0f;
    }

    //--------------------------------------------------------------------------------------------------
    // Export Functions
    //--------------------------------------------------------------------------------------------------
    void MSXAnalyzer::exportMetricsCSV(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("Failed to open CSV file: %s\n", filepath.c_str());
            return;
        }

        // Header
        file << "Method,Material,Roughness,SampleCount,MSE,PSNR,SSIM,EnergyLoss,FurnaceError,"
            << "RenderTimeMs,HasArtifacts,HasSpecularPeak,IsTooDark,Notes\n";

        // Data
        for (const auto& m : m_metrics)
        {
            file << getMethodName(m.method) << ","
                << getMaterialName(m.material) << ","
                << m.roughness << ","
                << m.sampleCount << ","
                << std::fixed << std::setprecision(8) << m.mse << ","
                << std::fixed << std::setprecision(3) << m.psnr << ","
                << std::fixed << std::setprecision(4) << m.ssim << ","
                << std::fixed << std::setprecision(6) << m.energyLoss << ","
                << std::fixed << std::setprecision(6) << m.furnaceTestError << ","
                << std::fixed << std::setprecision(2) << m.renderTimeMs << ","
                << (m.hasArtifacts ? "true" : "false") << ","
                << (m.hasSpecularPeak ? "true" : "false") << ","
                << (m.isTooDark ? "true" : "false") << ","
                << "\"" << m.notes << "\"\n";
        }

        file.close();
        LOGI("Exported metrics to: %s\n", filepath.c_str());
    }

    void MSXAnalyzer::exportMSEvsRoughnessCSV(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("Failed to open CSV file: %s\n", filepath.c_str());
            return;
        }

        // Header - one column per method
        file << "Roughness";
        std::vector<MSXMethod> methods;
        for (const auto& m : m_metrics)
        {
            if (std::find(methods.begin(), methods.end(), m.method) == methods.end())
            {
                methods.push_back(m.method);
                file << "," << getMethodName(m.method);
            }
        }
        file << "\n";

        // Data - one row per roughness value
        for (float roughness : m_config.roughnessValues)
        {
            file << roughness;

            for (const auto& method : methods)
            {
                // Find MSE for this method/roughness (use first material, usually achromatic)
                double mse = 0.0;
                for (const auto& m : m_metrics)
                {
                    if (m.method == method && std::abs(m.roughness - roughness) < 0.01f)
                    {
                        mse = m.mse;
                        break;
                    }
                }
                file << "," << std::scientific << std::setprecision(6) << mse;
            }
            file << "\n";
        }

        file.close();
        LOGI("Exported MSE vs Roughness to: %s\n", filepath.c_str());
    }

    void MSXAnalyzer::exportPerformanceCSV(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("Failed to open CSV file: %s\n", filepath.c_str());
            return;
        }

        // Header
        file << "Roughness";
        std::vector<MSXMethod> methods;
        for (const auto& m : m_metrics)
        {
            if (std::find(methods.begin(), methods.end(), m.method) == methods.end())
            {
                methods.push_back(m.method);
                file << "," << getMethodName(m.method);
            }
        }
        file << "\n";

        // Data
        for (float roughness : m_config.roughnessValues)
        {
            file << roughness;

            for (const auto& method : methods)
            {
                double avgTime = 0.0;
                int count = 0;

                for (const auto& m : m_metrics)
                {
                    if (m.method == method && std::abs(m.roughness - roughness) < 0.01f)
                    {
                        avgTime += m.renderTimeMs;
                        count++;
                    }
                }

                if (count > 0)
                    avgTime /= count;

                file << "," << std::fixed << std::setprecision(2) << avgTime;
            }
            file << "\n";
        }

        file.close();
        LOGI("Exported performance to: %s\n", filepath.c_str());
    }

    void MSXAnalyzer::exportComparisonImages(const std::string& directory)
    {
        std::filesystem::create_directories(directory);

        for (const auto& frame : m_capturedFrames)
        {
            std::stringstream ss;
            ss << directory << "/"
                << getMethodName(frame.method) << "_"
                << getMaterialName(frame.material) << "_"
                << "alpha" << std::fixed << std::setprecision(2) << frame.roughness
                << ".png";

            saveImage(ss.str(), frame.data);
        }

        LOGI("Exported %zu comparison images to: %s\n", m_capturedFrames.size(), directory.c_str());
    }

    void MSXAnalyzer::exportResultGrid(const std::string& filepath, const std::vector<float>& roughnessValues)
    {
        // Create a grid image similar to Figure 14 from the paper
        // This would require stitching multiple images together
        // For now, just log that it's not implemented
        LOGI("Result grid export not yet implemented: %s\n", filepath.c_str());
    }

    void MSXAnalyzer::exportFurnaceTestResults(const std::string& directory)
    {
        std::filesystem::create_directories(directory);

        std::string csvPath = directory + "/furnace_test.csv";
        std::ofstream file(csvPath);

        if (file.is_open())
        {
            file << "Method,Roughness,FurnaceError\n";

            for (const auto& m : m_metrics)
            {
                if (m.furnaceTestError > 0.0)
                {
                    file << getMethodName(m.method) << ","
                        << m.roughness << ","
                        << std::fixed << std::setprecision(6) << m.furnaceTestError << "\n";
                }
            }

            file.close();
            LOGI("Exported furnace test results to: %s\n", csvPath.c_str());
        }
    }

    void MSXAnalyzer::generatePlotScript(const std::string& filepath)
    {
        std::ofstream file(filepath);
        if (!file.is_open())
        {
            LOGE("Failed to create plot script: %s\n", filepath.c_str());
            return;
        }

        file << R"(#!/usr/bin/env python3
"""
MSX Analysis Plotting Script
Auto-generated by MSXAnalyzer

Usage: python plot_results.py
"""

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path

# Load data
metrics_df = pd.read_csv('msx_metrics.csv')
mse_df = pd.read_csv('mse_vs_roughness.csv')
perf_df = pd.read_csv('performance.csv')

# Figure 1: MSE vs Roughness (Paper Figure 9 style)
plt.figure(figsize=(10, 6))
methods = mse_df.columns[1:]  # Skip 'Roughness' column
for method in methods:
    plt.semilogy(mse_df['Roughness'], mse_df[method], marker='o', label=method)
plt.xlabel('Roughness (α)')
plt.ylabel('MSE (log scale)')
plt.title('MSE vs Roughness - Comparison to Reference')
plt.legend()
plt.grid(True, alpha=0.3)
plt.savefig('mse_vs_roughness.png', dpi=300, bbox_inches='tight')
print("Saved: mse_vs_roughness.png")

# Figure 2: Performance Comparison (Paper Figure 9 bottom style)
plt.figure(figsize=(10, 6))
for method in perf_df.columns[1:]:
    plt.plot(perf_df['Roughness'], perf_df[method], marker='s', label=method)
plt.xlabel('Roughness (α)')
plt.ylabel('Render Time (ms)')
plt.title('Performance Comparison')
plt.legend()
plt.grid(True, alpha=0.3)
plt.savefig('performance_comparison.png', dpi=300, bbox_inches='tight')
print("Saved: performance_comparison.png")

# Figure 3: PSNR Comparison
plt.figure(figsize=(10, 6))
for method in metrics_df['Method'].unique():
    method_data = metrics_df[metrics_df['Method'] == method]
    plt.plot(method_data['Roughness'], method_data['PSNR'], marker='o', label=method)
plt.xlabel('Roughness (α)')
plt.ylabel('PSNR (dB)')
plt.title('PSNR vs Roughness')
plt.legend()
plt.grid(True, alpha=0.3)
plt.savefig('psnr_comparison.png', dpi=300, bbox_inches='tight')
print("Saved: psnr_comparison.png")

# Figure 4: Energy Loss
plt.figure(figsize=(10, 6))
for method in metrics_df['Method'].unique():
    method_data = metrics_df[metrics_df['Method'] == method]
    plt.plot(method_data['Roughness'], method_data['EnergyLoss'], marker='o', label=method)
plt.xlabel('Roughness (α)')
plt.ylabel('Energy Loss')
plt.title('Energy Loss vs Roughness')
plt.legend()
plt.grid(True, alpha=0.3)
plt.savefig('energy_loss.png', dpi=300, bbox_inches='tight')
print("Saved: energy_loss.png")

# Summary statistics
print("\n=== Summary Statistics ===")
for method in metrics_df['Method'].unique():
    method_data = metrics_df[metrics_df['Method'] == method]
    print(f"\n{method}:")
    print(f"  Avg MSE: {method_data['MSE'].mean():.6e}")
    print(f"  Avg PSNR: {method_data['PSNR'].mean():.2f} dB")
    print(f"  Avg Time: {method_data['RenderTimeMs'].mean():.2f} ms")
    print(f"  Artifacts: {method_data['HasArtifacts'].sum()} / {len(method_data)}")

print("\n=== Plots generated successfully ===")
)";

        file.close();

        // Make executable on Unix systems
#ifndef _WIN32
        std::filesystem::permissions(filepath,
            std::filesystem::perms::owner_exec |
            std::filesystem::perms::group_exec,
            std::filesystem::perm_options::add);
#endif

        LOGI("Generated plot script: %s\n", filepath.c_str());
    }

    //--------------------------------------------------------------------------------------------------
    // Helper Functions
    //--------------------------------------------------------------------------------------------------
    std::vector<float> MSXAnalyzer::downloadImage(VkCommandBuffer cmd, VkImage image)
    {
        size_t pixelCount = m_config.resolution.width * m_config.resolution.height;
        std::vector<float> data(pixelCount * 4);  // RGBA

        if (image == VK_NULL_HANDLE || cmd == VK_NULL_HANDLE)
        {
            LOGE("downloadImage: Invalid image or command buffer\n");
            return data;
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
        region.imageExtent = { m_config.resolution.width, m_config.resolution.height, 1 };

        vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            m_stagingBuffer.buffer, 1, &region);

        // Transition back to GENERAL
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;

        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0, 0, nullptr, 0, nullptr, 1, &barrier);

        return data;
    }

    void MSXAnalyzer::readStagingBuffer(std::vector<float>& outData)
    {
        // Use m_resolution (set from actual image) not m_config.resolution (default)
        size_t pixelCount = m_resolution.width * m_resolution.height;
        outData.resize(pixelCount * 4);

        // Map staging buffer and read data
        void* mapped = nullptr;
        VkResult result = vmaMapMemory(*m_allocator, m_stagingBuffer.allocation, &mapped);
        if (result == VK_SUCCESS && mapped != nullptr)
        {
            std::memcpy(outData.data(), mapped, outData.size() * sizeof(float));
            vmaUnmapMemory(*m_allocator, m_stagingBuffer.allocation);
        }
        else
        {
            LOGE("Failed to map staging buffer for reading\n");
        }
    }

    void MSXAnalyzer::saveImage(const std::string& filepath, const std::vector<float>& data)
    {
        if (data.empty())
        {
            LOGE("Cannot save empty image data\n");
            return;
        }

        std::filesystem::path path(filepath);
        std::string ext = path.extension().string();

        if (ext.empty())
        {
            ext = ".hdr";
            path += ext;
        }

        bool success = false;

        if (ext == ".hdr")
        {
            // Save as HDR format for accurate comparison
            success = stbi_write_hdr(path.string().c_str(), m_config.resolution.width,
                m_config.resolution.height, 4, data.data());
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
                success = stbi_write_png(path.string().c_str(), m_config.resolution.width,
                    m_config.resolution.height, 4, ldrData.data(), m_config.resolution.width * 4);
            }
            else if (ext == ".jpg")
            {
                success = stbi_write_jpg(path.string().c_str(), m_config.resolution.width,
                    m_config.resolution.height, 4, ldrData.data(), 95);
            }
            else if (ext == ".bmp")
            {
                success = stbi_write_bmp(path.string().c_str(), m_config.resolution.width,
                    m_config.resolution.height, 4, ldrData.data());
            }
        }

        if (success)
        {
            LOGI("Saved image: %s (%ux%u)\n", path.string().c_str(),
                m_config.resolution.width, m_config.resolution.height);
        }
        else
        {
            LOGE("Failed to save image: %s\n", path.string().c_str());
        }
    }

    std::vector<float> MSXAnalyzer::loadImage(const std::string& filepath, uint32_t& width, uint32_t& height)
    {
        // Load HDR image
        int w, h, channels;
        float* imageData = stbi_loadf(filepath.c_str(), &w, &h, &channels, 4);

        if (!imageData)
        {
            LOGE("Failed to load image: %s\n", filepath.c_str());
            return {};
        }

        width = w;
        height = h;

        std::vector<float> data(w * h * 4);
        std::memcpy(data.data(), imageData, data.size() * sizeof(float));

        stbi_image_free(imageData);

        return data;
    }

    std::string MSXAnalyzer::getReferenceKey(TestMaterial material, float roughness) const
    {
        std::stringstream ss;
        ss << getMaterialName(material) << "_alpha" << std::fixed << std::setprecision(2) << roughness;
        return ss.str();
    }

    const std::vector<float>* MSXAnalyzer::getReference(TestMaterial material, float roughness)
    {
        std::string key = getReferenceKey(material, roughness);
        auto it = m_referenceImages.find(key);

        if (it != m_referenceImages.end())
            return &it->second;

        return nullptr;
    }

    MSXMetrics* MSXAnalyzer::getMetrics(MSXMethod method, TestMaterial material, float roughness)
    {
        for (auto& m : m_metrics)
        {
            if (m.method == method && m.material == material && std::abs(m.roughness - roughness) < 0.01f)
                return &m;
        }
        return nullptr;
    }

    MSXAnalyzer::TestSummary MSXAnalyzer::getTestSummary(MSXMethod method) const
    {
        TestSummary summary;

        for (const auto& m : m_metrics)
        {
            if (m.method == method)
            {
                summary.avgMSE += m.mse;
                summary.avgPSNR += m.psnr;
                summary.avgRenderTime += m.renderTimeMs;
                if (m.hasArtifacts || m.hasSpecularPeak)
                    summary.artifactCount++;
                summary.totalTests++;
            }
        }

        if (summary.totalTests > 0)
        {
            summary.avgMSE /= summary.totalTests;
            summary.avgPSNR /= summary.totalTests;
            summary.avgRenderTime /= summary.totalTests;
        }

        return summary;
    }

    void MSXAnalyzer::setupFurnaceTest()
    {
        m_furnaceTestActive = true;
        // TODO: Replace HDRI with uniform white environment
        LOGI("Furnace test environment activated\n");
    }

    void MSXAnalyzer::restoreFurnaceTest()
    {
        m_furnaceTestActive = false;
        // TODO: Restore original HDRI
        LOGI("Normal test environment restored\n");
    }

    std::string MSXAnalyzer::getMaterialName(TestMaterial material)
    {
        switch (material)
        {
        case TestMaterial::Achromatic: return "Achromatic";
        case TestMaterial::Copper:     return "Copper";
        case TestMaterial::Gold:       return "Gold";
        case TestMaterial::Custom:     return "Custom";
        default:                       return "Unknown";
        }
    }

    std::string MSXAnalyzer::getMethodName(MSXMethod method)
    {
        switch (method)
        {
        case MSXMethod::GGX:       return "GGX";
        case MSXMethod::FastMSX:   return "FastMSX";
        case MSXMethod::HeitzMS:   return "HeitzMS";
        case MSXMethod::LeeMS:     return "LeeMS";
        case MSXMethod::WangMS:    return "WangMS";
        case MSXMethod::TurquinMS: return "TurquinMS";
        default:                   return "Unknown";
        }
    }

}  // namespace matforge