# Bounded VNDF + Fast-MSX Implementation Plan

**Developer**: Person C (Material Specialist)
**Timeline**: November 3 - December 7, 2025 (5 weeks)
**Scope**: ~350 LOC (Bounded VNDF ~200 LOC + Fast-MSX ~150 LOC)
**Papers**:
1. "Bounded VNDF Sampling for Smith-GGX Reflections", Eto & Tokuyoshi (AMD), SIGGRAPH Asia 2023
2. "Fast-MSX: Fast Multiple Scattering Approximation", SIGGRAPH 2023
**Location**: [doc/papers/bounded_VNDF.pdf](../papers/bounded_VNDF.pdf)

---

## Executive Summary

**What are Bounded VNDF and Fast-MSX?**

**Bounded VNDF** improves the efficiency of importance sampling for GGX microfacet materials by **reducing rejected samples**. Instead of sampling the full upper hemisphere for visible normals, it uses a tighter **spherical cap bound** that avoids reflection vectors occluded by the surface.

**Fast-MSX** adds **multiple scattering** to microfacet BRDFs using a **closed-form approximation**. Standard GGX only accounts for single-bounce reflections, causing rough materials to appear too dark. Fast-MSX adds a second-order scattering term with **~5% overhead** while improving energy conservation by **100× at high roughness**.

**Why These Two Together?**
- **Bounded VNDF**: Better *sampling* (how we generate directions)
- **Fast-MSX**: Better *evaluation* (how we compute BRDF)
- **Synergy**: Sample efficiently, evaluate accurately → best quality per sample
- **Material Focus**: Both improve material appearance, making Person C the "Material Specialist"

**Implementation Strategy**:
- **Week 1**: Setup, study papers, locate integration points in codebase
- **Week 2**: Bounded VNDF implementation (drop-in GGX sampler replacement)
- **Week 3**: Fast-MSX implementation + integration with Bounded VNDF
- **Week 4-5**: Material library, performance analysis, polish

---

## 1. Team Structure

### Person C: Material Specialist

**Role**: Material Rendering Quality - Sampling + Shading

**Responsibilities**:
- **Bounded VNDF**: Efficient GGX importance sampling (Week 2)
- **Fast-MSX**: Multi-scatter BRDF evaluation (Week 3)
- **Material System**: Library of 7+ materials showcasing both techniques
- **Analysis**: Variance reduction, energy conservation, quality metrics
- **UI**: Material parameter editor with live preview

**Dependencies** (Others → Person C):
- **Person B (Quad LDS)**: Better random numbers improve Person C's sampling quality
- **Person A (RMIP)**: Displaced geometry combined with Person C's materials

**Benefits to Others**:
- **Person A**: RMIP displaced surfaces look better with Fast-MSX shading
- **Person B**: Quad LDS convergence benefits amplified by efficient sampling

**Communication**:
- Team standups: Mon/Wed/Fri (3-person team)
- Integration handoffs: Week 3 (Bounded VNDF + Quad LDS), Week 4 (Full pipeline)
- Milestones: Nov 12 (M1), Nov 24 (M2), Dec 1 (M3), Dec 7 (Final)

---

## 2. Work Division

### Phase 1: Bounded VNDF (Week 1-2)

**Goal**: Replace standard VNDF sampling with bounded version

**Components**:
1. **Spherical Cap Bounding** (~80 LOC)
   - Compute tighter lower bound: `-k * i_z` instead of `-i_z`
   - Isotropic roughness: exact bound
   - Anisotropic roughness: conservative bound
   - Integration with existing `SampleGGXVNDF()` function

2. **PDF Computation** (~50 LOC)
   - Update PDF for bounded sampling range
   - Handle backfacing shading normals
   - Numerically stable implementation

3. **Validation** (~70 LOC)
   - Rejection rate measurement tool
   - Variance comparison (bounded vs. standard)
   - Visual validation scenes

### Phase 2: Fast-MSX (Week 3)

**Goal**: Add multi-scatter term to GGX BRDF

**Components**:
1. **Fast-MSX BRDF Evaluation** (~100 LOC)
   - Algorithm 1 from paper (~20 lines core logic)
   - Cavity orientation: `c = normalize(h + n)`
   - Modified GGX terms: `D_I`, `G_I`, `F_I`
   - Early exit for smooth surfaces (α < 0.3)

2. **Integration with Path Tracer** (~30 LOC)
   - Modify `evaluateMaterial()` in `pbr_material_eval.h.slang`
   - Additive combination: `f_total = f_ss + f_ms`
   - Roughness-dependent toggle

3. **Validation** (~20 LOC)
   - MSE vs. ground truth
   - Energy conservation test (furnace test)
   - Visual comparison (GGX vs. Fast-MSX)

### Phase 3: Material System (Week 4-5)

**Goal**: Material library showcasing both techniques

**Components**:
1. **Material Library** (7+ materials)
   - Rough stone, hammered copper, wood, concrete, velvet, ceramic, brick
   - Varying roughness (α = 0.2 to 0.9)
   - Metallic and dielectric
   - Combination with RMIP displacement

2. **Material Editor** (UI in ImGui)
   - Roughness slider (0.0 - 1.0)
   - Metallic toggle
   - Anisotropy control
   - Fast-MSX enable/disable
   - Live preview

3. **Analysis Tools**
   - Convergence comparison
   - Quality metrics (MSE, RMSE)
   - Performance profiling

---

## 3. Week-by-Week Schedule

### Week 1: Nov 3-9 (Setup & Foundation)

**Goal**: Understand codebase, locate integration points, create test scenes

**Monday Nov 3**:
- Fork vk_gltf_renderer, set up build environment
- Build and run existing renderer
- Load sample glTF scenes (DamagedHelmet, MetalRoughSpheres)
- Verify path tracer working correctly

**Tuesday Nov 4**:
- Read Bounded VNDF paper (focus on Section 3: Our Method)
- Read Fast-MSX paper (focus on Algorithm 1)
- Understand the two-stage pipeline:
  - Stage 1: Sample direction (Bounded VNDF)
  - Stage 2: Evaluate BRDF (Fast-MSX)
- Document integration strategy

**Wednesday Nov 5**:
- Locate existing GGX sampler in codebase:
  - Search for `SampleGGXVNDF` in `shaders/`
  - Find in `nvpro_core2/nvshaders/pbr_ggx_microfacet.h.slang`
- Study current implementation (Dupuy & Benyoub 2023 method)
- Identify sampling call sites in `gltf_pathtrace.slang`
- Document current VNDF pipeline

**Thursday Nov 6**:
- Locate existing BRDF evaluation:
  - `pbr_material_eval.h.slang` - main material evaluation
  - `pbr_ggx_microfacet.h.slang` - GGX functions
- Understand BRDF call chain: `evaluateMaterial() → evaluateGGX()`
- Identify where to inject Fast-MSX term
- Document current BRDF pipeline

**Friday Nov 7**:
- Create test scene: 5 spheres with varying roughness
  - Sphere 1: α = 0.1 (smooth)
  - Sphere 2: α = 0.3 (low roughness)
  - Sphere 3: α = 0.5 (medium roughness)
  - Sphere 4: α = 0.7 (high roughness)
  - Sphere 5: α = 0.9 (very rough)
- Create baseline renders for comparison
- **Checkpoint 1**: Understanding complete, test scene ready

**Weekend (Optional)**:
- Review Bounded VNDF supplemental material
- Study HLSL code examples from paper (Listing 1 & 2)
- Prepare for Week 2 implementation

---

### Week 2: Nov 10-15 (Bounded VNDF Implementation)

**Goal**: Working Bounded VNDF sampler, validated, demo ready

**Monday Nov 11**:
- Create `shaders/bounded_vndf.h.slang` (new file)
- Implement spherical cap bound computation:
  ```slang
  // Compute k for isotropic roughness
  float computeSphericalCapBound(float3 i, float alpha) {
      float s = 1.0 + length(i.xy);  // For alpha <= 1
      float a2 = alpha * alpha;
      float s2 = s * s;
      float k = (1.0 - a2) * s2 / (s2 + a2 * i.z * i.z);
      return k;
  }
  ```
- Unit test: Verify bound computation for known cases

**Tuesday Nov 12**: **MILESTONE 1 PRESENTATION**
- Morning: Implement modified sampling function
  ```slang
  float3 SampleBoundedGGXReflection(float3 i, float2 alpha, float2 rand) {
      // Stretch incoming direction
      float3 i_std = normalize(float3(i.xy * alpha, i.z));

      // Compute bound
      float a = saturate(min(alpha.x, alpha.y));  // Conservative for anisotropic
      float s = 1.0 + length(i.xy);
      float k = (1.0 - a*a) * s*s / (s*s + a*a * i.z*i.z);

      // Sample spherical cap with tighter bound
      float b = i.z > 0 ? k * i_std.z : i_std.z;  // Use -k*i_z or -i_z
      float z = mad(1.0 - rand.y, 1.0 + b, -b);

      // ... rest of sampling (same as Dupuy & Benyoub)
  }
  ```
- Test sampling: Generate 1000 samples, verify none are rejected
- Afternoon: **Milestone 1 Presentation**
- **Deliverable**: Basic Bounded VNDF working (even if not fully optimized)

**Wednesday Nov 13**:
- Implement PDF computation for bounded sampling:
  ```slang
  float BoundedGGXReflectionPDF(float3 i, float3 o, float2 alpha) {
      float3 m = normalize(i + o);
      float D = GGX_D(m, alpha);

      if (i.z >= 0) {
          float a = saturate(min(alpha.x, alpha.y));
          float s = 1.0 + length(i.xy);
          float k = (1.0 - a*a) * s*s / (s*s + a*a * i.z*i.z);
          float t = sqrt(dot(alpha * i.xy, alpha * i.xy) + i.z*i.z);
          return D / (2.0 * (k * i.z + t));  // Bounded PDF
      } else {
          // Backfacing: use previous PDF
          float t = sqrt(dot(alpha * i.xy, alpha * i.xy) + i.z*i.z);
          return D * (t - i.z) / (2.0 * dot(alpha * i.xy, alpha * i.xy));
      }
  }
  ```
- Verify PDF integrates to 1 (numerical integration test)

**Thursday Nov 14**:
- Integrate Bounded VNDF into path tracer
- Replace existing `SampleGGXVNDF()` calls in `gltf_pathtrace.slang`
- Add UI toggle: "Use Bounded VNDF" checkbox
- Conditional sampling:
  ```slang
  if (pushConst.useBoundedVNDF) {
      wi = SampleBoundedGGXReflection(wo, alpha, rand);
      pdf = BoundedGGXReflectionPDF(wo, wi, alpha);
  } else {
      wi = SampleGGXVNDF(wo, alpha, rand);  // Original
      pdf = GGX_VNDF_PDF(wo, wi, alpha);
  }
  ```
- First integration test: Render test scene with bounded VNDF

**Friday Nov 15**:
- Create rejection rate measurement tool:
  ```cpp
  struct RejectionStats {
      uint totalSamples;
      uint rejectedSamples;
      float rejectionRate() { return rejectedSamples / (float)totalSamples; }
  };
  ```
- Measure rejection rates for standard vs. bounded VNDF
- Create comparison images:
  - Equal sample count (256 spp)
  - Equal render time (how many more samples with bounded?)
- **Checkpoint 2**: Bounded VNDF working, validated, comparison data collected

**Weekend (Optional)**:
- Review Fast-MSX paper in detail
- Study Algorithm 1 (the core 20-line algorithm)
- Understand cavity orientation concept

---

### Week 3: Nov 18-22 (Fast-MSX Implementation + Integration)

**Goal**: Fast-MSX working, integrated with Bounded VNDF, validated

**Monday Nov 18**:
- Create `shaders/fastmsx.h.slang` (new file)
- Implement cavity orientation computation:
  ```slang
  // Compute cavity orientation (Eq. 7)
  float3 computeCavityOrientation(float3 V, float3 L, float3 N) {
      float3 H = normalize(V + L);  // Half-vector
      float3 C = normalize(H + N);  // Cavity orientation
      return C;
  }
  ```
- Implement Fresnel-Schlick helper:
  ```slang
  float3 fresnelSchlick(float cosTheta, float3 F0) {
      return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
  }
  ```

**Tuesday Nov 19**:
- Implement Fast-MSX core algorithm (Algorithm 1):
  ```slang
  struct FastMSXResult {
      float3 f_ms;    // Multi-scatter term
      float weight;   // Contribution weight
  };

  FastMSXResult evaluateFastMSX(float3 V, float3 L, float3 N,
                                 float alpha, float3 F0) {
      FastMSXResult result;

      // Early exit for smooth surfaces
      if (alpha < 0.3) {
          result.f_ms = float3(0, 0, 0);
          result.weight = 0.0;
          return result;
      }

      // Step 1: Cavity orientation
      float3 H = normalize(V + L);
      float3 C = normalize(H + N);

      // Step 2: Geometry term G_I (relaxed V-cavity)
      float CoV = max(dot(C, V), 0.0);
      float CoL = max(dot(C, L), 0.0);
      float G1_V = CoV / (CoV + alpha * sqrt(1.0 - CoV * CoV));
      float G1_L = CoL / (CoL + alpha * sqrt(1.0 - CoL * CoL));
      float G_I = G1_V * G1_L;

      // Step 3: Distribution term D_I (modified GGX)
      float CoH = max(dot(C, H), 0.0);
      float alpha2 = alpha * alpha;
      float denom = CoH * CoH * (alpha2 - 1.0) + 1.0;
      float D_I = alpha2 / (PI * denom * denom);

      // Step 4: Fresnel term F_I (F² approximation)
      float3 F_single = fresnelSchlick(CoV, F0);
      float3 F_I = F_single * F_single;

      // Step 5: Combine multi-scatter term
      float NoV = max(dot(N, V), 0.0);
      result.f_ms = (D_I * G_I * F_I) / (2.0 * NoV + 1e-5);
      result.weight = 1.0;

      return result;
  }
  ```
- Unit test: Verify output for known inputs (compare with paper figures)

**Wednesday Nov 20**:
- Integrate Fast-MSX into material evaluation
- Modify `pbr_material_eval.h.slang`:
  ```slang
  #include "fastmsx.h.slang"

  float3 evaluateMaterial(PbrMaterial mat, float3 V, float3 L, float3 N) {
      // Single-scatter GGX (existing)
      float3 f_ss = evaluateGGX(V, L, N, mat.roughness, mat.f0);

      // Multi-scatter Fast-MSX (new)
      if (pushConst.useFastMSX) {
          float alpha = mat.roughness * mat.roughness;
          FastMSXResult msx = evaluateFastMSX(V, L, N, alpha, mat.f0);
          return f_ss + msx.f_ms;  // Additive
      }

      return f_ss;
  }
  ```
- Add UI toggle: "Enable Fast-MSX" checkbox
- First integration test: Render with Fast-MSX enabled

**Thursday Nov 21**:
- Test combined Bounded VNDF + Fast-MSX pipeline:
  ```
  Pipeline: Sample with Bounded VNDF → Evaluate with Fast-MSX
  ```
- Verify no interference between techniques
- Create side-by-side comparison:
  - Standard GGX (VNDF + single-scatter)
  - Bounded only (Bounded VNDF + single-scatter)
  - Fast-MSX only (VNDF + Fast-MSX)
  - Both (Bounded VNDF + Fast-MSX)
- Measure combined benefit (variance + quality)

**Friday Nov 22**:
- Quality validation: MSE vs. ground truth
  - Render reference at 16384 spp (standard GGX)
  - Compare at 256 spp:
    - Standard GGX
    - Bounded VNDF only
    - Fast-MSX only
    - Both combined
- Create comparison tables and graphs
- Test on varying roughness (α = 0.1 to 0.9)
- **Checkpoint 3**: Fast-MSX working, integrated with Bounded VNDF, validated

**Weekend (Optional)**:
- Prepare material library plan
- Source textures (displacement, albedo, roughness maps)
- Plan material parameters for 7+ materials

---

### Week 4: Nov 25-29 (Material Library + M2)

**Goal**: Complete material library, analysis, Milestone 2 presentation

**Monday Nov 25**:
- Create material library (7+ materials):

  **Material 1: Rough Stone**
  - Base color: Gray (0.5, 0.5, 0.5)
  - Roughness: α = 0.7 (high roughness - showcase Fast-MSX)
  - Metallic: 0.0
  - Displacement: High-frequency noise texture
  - Showcase: Fast-MSX energy conservation + RMIP detail

  **Material 2: Hammered Copper**
  - Base color: Copper (0.95, 0.64, 0.54)
  - Roughness: α = 0.4 (medium roughness)
  - Metallic: 1.0
  - Displacement: Hammered pattern texture
  - Showcase: Metallic Fast-MSX + structured displacement

  **Material 3: Wood Planks**
  - Base color: Brown wood (0.6, 0.4, 0.2)
  - Roughness: α_x = 0.3, α_y = 0.6 (anisotropic)
  - Metallic: 0.0
  - Displacement: Wood grain texture
  - Showcase: Anisotropic Bounded VNDF + grain detail

**Tuesday Nov 26**: **MILESTONE 2 PRESENTATION**
- Morning: Create remaining materials

  **Material 4: Concrete**
  - Base color: Light gray (0.6, 0.6, 0.6)
  - Roughness: α = 0.5 (medium)
  - Metallic: 0.0
  - Displacement: Mid-frequency noise
  - Showcase: Balanced roughness + displacement

  **Material 5: Velvet/Fabric**
  - Base color: Deep red (0.6, 0.1, 0.1)
  - Roughness: α = 0.9 (very rough - maximum Fast-MSX benefit)
  - Metallic: 0.0
  - Displacement: None (showcase Fast-MSX alone)
  - Showcase: Highest Fast-MSX contribution

  **Material 6: Ceramic**
  - Base color: White (0.9, 0.9, 0.9)
  - Roughness: α = 0.3 (low-medium)
  - Metallic: 0.0
  - Displacement: Subtle surface texture
  - Showcase: Bounded VNDF efficiency at low roughness

  **Material 7: Brick Wall**
  - Base color: Red-orange (0.7, 0.3, 0.2)
  - Roughness: α = 0.5
  - Metallic: 0.0
  - Displacement: Tiled brick pattern
  - Showcase: Tiled displacement + realistic roughness

- Afternoon: **Milestone 2 Presentation**
- **Deliverable**: Complete material library, both techniques integrated

**Wednesday Nov 27**: **THANKSGIVING**
- (Optional) Code review and documentation

**Thursday Nov 28**: **THANKSGIVING**
- (No work expected)

**Friday Nov 29**:
- Performance analysis for each technique:

  **Bounded VNDF Analysis**:
  - Rejection rate vs. roughness (plot)
  - Variance reduction vs. roughness (table)
  - Overhead per sample (GPU timing)
  - Most effective range: α = 0.5 - 1.0

  **Fast-MSX Analysis**:
  - MSE vs. ground truth for each roughness level
  - Energy conservation improvement (vs. standard GGX)
  - Overhead vs. roughness (should be constant ~5%)
  - Most effective range: α = 0.5 - 0.9

  **Combined Analysis**:
  - Synergy between techniques
  - Total quality improvement per render time
  - Best-case scenarios (rough dielectrics)

**Weekend (Optional)**:
- Prepare Milestone 3 materials
- Create demo video script

---

### Week 5: Dec 2-7 (Polish & Final)

**Goal**: Final optimization, documentation, Milestone 3 + Final submission

**Monday Dec 1**: **MILESTONE 3 PRESENTATION**
- Morning: Create material parameter editor
  ```cpp
  // In ui_renderer.cpp
  void UiRenderer::renderMaterialEditor() {
      ImGui::SeparatorText("Material Parameters");

      ImGui::SliderFloat("Roughness", &mat.roughness, 0.0f, 1.0f);
      ImGui::SliderFloat("Metallic", &mat.metallic, 0.0f, 1.0f);
      ImGui::ColorEdit3("Base Color", &mat.baseColor);

      ImGui::SeparatorText("Bounded VNDF");
      ImGui::Checkbox("Enable Bounded VNDF", &settings.useBoundedVNDF);
      if (settings.useBoundedVNDF) {
          ImGui::Text("Rejection rate: %.2f%%", stats.rejectionRate * 100);
      }

      ImGui::SeparatorText("Fast-MSX");
      ImGui::Checkbox("Enable Fast-MSX", &settings.useFastMSX);
      if (settings.useFastMSX) {
          ImGui::SliderFloat("MSX Threshold", &settings.msxAlphaThreshold, 0.0f, 0.5f);
          ImGui::Text("Multi-scatter contribution: %.2f", msx.weight);
      }

      ImGui::SeparatorText("Displacement (RMIP)");
      ImGui::SliderFloat("Displacement Scale", &mat.dispScale, 0.0f, 0.5f);
  }
  ```
- Live preview with parameter changes
- Afternoon: **Milestone 3 Presentation**
- **Deliverable**: Material editor, final integration

**Tuesday Dec 2**:
- Code cleanup: Remove debug code, add comments
- Optimize shader code:
  ```slang
  // Fast-MSX optimization: Early exit for smooth surfaces
  if (alpha < 0.3) return f_ss;  // Skip Fast-MSX computation

  // Bounded VNDF optimization: Precompute constants
  float a2 = alpha * alpha;
  float s2 = s * s;
  float k = (1.0 - a2) * s2 / (s2 + a2 * i.z * i.z);  // Shared computation
  ```
- Profile GPU performance: NSight Graphics or RenderDoc
- Measure per-technique overhead

**Wednesday Dec 3**:
- Create comprehensive documentation:

  **Bounded VNDF Documentation** (`docs/BoundedVNDF_Guide.md`):
  - Algorithm overview
  - Implementation details
  - Integration guide
  - Performance characteristics
  - When to use (α > 0.5)

  **Fast-MSX Documentation** (`docs/FastMSX_Guide.md`):
  - Algorithm overview (cavity orientation, relaxed V-cavity)
  - Implementation details
  - Integration guide
  - Energy conservation analysis
  - When to use (α > 0.3)

  **Material Library Documentation** (`docs/Material_Library.md`):
  - Description of each material
  - Parameter ranges
  - Texture sources and attribution
  - Usage examples

**Thursday Dec 4**:
- Final validation: Re-run all tests
- Create comparison table:

  | Technique | Variance Reduction | Overhead | Best For |
  |-----------|-------------------|----------|----------|
  | Bounded VNDF | 15-40% (α=0.6-1.0) | <1% | Rough surfaces |
  | Fast-MSX | 100× MSE (α=0.7) | ~5% | Rough materials |
  | Combined | 20-50% | ~6% | Rough dielectrics/metals |

- Prepare final presentation materials:
  - Slides for Person C section (techniques overview)
  - Demo video (material library showcase)
  - Before/after comparisons
  - Performance graphs

**Friday Dec 5**:
- Team integration day: Test full pipeline
  ```
  Quad LDS (Person B) → RMIP (Person A) → Bounded VNDF (Person C) → Fast-MSX (Person C)
  ```
- Verify all techniques work together
- Performance validation: FPS at different resolutions
- Final bug fixes

**Weekend Dec 6-7**: **FINAL PROJECT DUE**
- Saturday: Final presentation prep (all team members)
- Sunday: Final polish, submission preparation
- **Sunday Dec 7 4pm**: Final project due
- **Sunday Dec 7 5:30pm**: Live presentation

---

## 4. Detailed Task Breakdown

### Task Category A: Bounded VNDF Implementation

**A1. Spherical Cap Bound Computation** (~40 LOC)

```slang
// shaders/bounded_vndf.h.slang

// Compute bound factor k for spherical cap
// Paper: Equation 5
float computeBoundFactor(float3 i, float alpha) {
    // Isotropic case
    float s = 1.0 + length(i.xy);  // For alpha <= 1, use + sign
    float a2 = alpha * alpha;
    float s2 = s * s;
    float k = (1.0 - a2) * s2 / (s2 + a2 * i.z * i.z);
    return k;
}

// Conservative bound for anisotropic roughness
// Paper: Equation 6
float computeConservativeBound(float3 i, float2 alpha) {
    float alpha_min = saturate(min(alpha.x, alpha.y));
    return computeBoundFactor(i, alpha_min);
}
```

**A2. Modified VNDF Sampling** (~80 LOC)

```slang
// Replace Dupuy & Benyoub's sampling with bounded version
// Paper: Listing 1
float3 SampleBoundedGGXReflection(float3 i, float2 alpha, float2 rand) {
    // Step 1: Stretch incoming direction
    float3 i_std = normalize(float3(i.xy * alpha, i.z));

    // Step 2: Compute spherical cap bound
    float a = saturate(min(alpha.x, alpha.y));  // Conservative for anisotropic
    float s = 1.0 + length(float2(i.x, i.y));   // Omit sgn for a <= 1
    float a2 = a * a;
    float s2 = s * s;
    float k = (1.0 - a2) * s2 / (s2 + a2 * i.z * i.z);  // Equation 5

    // Step 3: Sample spherical cap with tighter bound
    float phi = 2.0 * PI * rand.x;
    float b = i.z > 0 ? k * i_std.z : i_std.z;  // Use -k*i_z or -i_z (backfacing)
    float z = mad(1.0 - rand.y, 1.0 + b, -b);  // Remap to [-b, 1]
    float sinTheta = sqrt(saturate(1.0 - z * z));
    float3 o_std = float3(sinTheta * cos(phi), sinTheta * sin(phi), z);

    // Step 4: Compute microfacet normal
    float3 m_std = i_std + o_std;

    // Step 5: Unstretch microfacet normal
    float3 m = normalize(float3(m_std.xy * alpha, m_std.z));

    // Step 6: Compute reflection vector
    return 2.0 * dot(i, m) * m - i;
}
```

**A3. PDF Computation** (~50 LOC)

```slang
// PDF for bounded VNDF sampling
// Paper: Listing 2, Equation 8
float BoundedGGXReflectionPDF(float3 i, float3 o, float2 alpha) {
    float3 m = normalize(i + o);
    float D = GGX_D(m, alpha);  // GGX distribution

    float2 ai = alpha * i.xy;
    float len2 = dot(ai, ai);
    float t = sqrt(len2 + i.z * i.z);

    if (i.z >= 0.0) {
        // Frontfacing: Use bounded PDF
        float a = saturate(min(alpha.x, alpha.y));
        float s = 1.0 + length(float2(i.x, i.y));
        float a2 = a * a;
        float s2 = s * s;
        float k = (1.0 - a2) * s2 / (s2 + a2 * i.z * i.z);

        // PDF = D / (2 * (k * i.z + t))
        // Multiply by Jacobian ||dm/do|| = 1/(4*|i·m|) already included
        return D / (2.0 * (k * i.z + t));
    } else {
        // Backfacing: Use previous PDF (numerically stable form)
        return D * (t - i.z) / (2.0 * len2);
    }
}
```

**A4. Integration into Path Tracer** (~30 LOC)

```slang
// In gltf_pathtrace.slang
#include "bounded_vndf.h.slang"

// Replace GGX sampling
if (mat.roughness > 0.01) {  // Glossy reflection
    float2 alpha = float2(mat.roughness * mat.roughness);  // GGX alpha

    if (pushConst.useBoundedVNDF) {
        // Use bounded VNDF sampling
        wi = SampleBoundedGGXReflection(wo, alpha, rand2D);
        pdf = BoundedGGXReflectionPDF(wo, wi, alpha);
    } else {
        // Use standard VNDF sampling
        wi = SampleGGXVNDF(wo, alpha, rand2D);
        pdf = GGX_VNDF_PDF(wo, wi, alpha);
    }

    // Check if sample is valid (upper hemisphere)
    if (dot(wi, N) <= 0.0) {
        // Should not happen with bounded VNDF for i.z > 0
        return float3(0, 0, 0);
    }
}
```

---

### Task Category B: Fast-MSX Implementation

**B1. Cavity Orientation Computation** (~15 LOC)

```slang
// shaders/fastmsx.h.slang

// Compute cavity orientation from view, light, and normal
// Paper: Equation 7
float3 computeCavityOrientation(float3 V, float3 L, float3 N) {
    float3 H = normalize(V + L);  // Half-vector (microfacet normal)
    float3 C = normalize(H + N);  // Cavity orientation
    return C;
}
```

**B2. Fast-MSX BRDF Evaluation** (~100 LOC)

```slang
// Fast-MSX multi-scatter BRDF evaluation
// Paper: Algorithm 1
struct FastMSXResult {
    float3 f_ms;    // Multi-scatter BRDF term
    float weight;   // Contribution weight (for analysis)
};

FastMSXResult evaluateFastMSX(
    float3 V,      // View direction (toward camera)
    float3 L,      // Light direction
    float3 N,      // Surface normal
    float alpha,   // Roughness (GGX alpha = roughness^2)
    float3 F0)     // Fresnel at normal incidence
{
    FastMSXResult result;

    // Early exit for smooth surfaces (no multi-scatter needed)
    if (alpha < 0.3) {
        result.f_ms = float3(0, 0, 0);
        result.weight = 0.0;
        return result;
    }

    // Step 1: Compute half-vector and cavity orientation
    float3 H = normalize(V + L);
    float3 C = normalize(H + N);  // Cavity orientation (Eq. 7)

    // Step 2: Compute geometry term G_I (relaxed V-cavity, Eq. 8-9)
    float NoV = max(dot(N, V), 0.0);
    float NoL = max(dot(N, L), 0.0);
    float CoV = max(dot(C, V), 0.0);
    float CoL = max(dot(C, L), 0.0);

    // G1 terms for cavity (Eq. 9)
    float denom_V = CoV + alpha * sqrt(1.0 - CoV * CoV);
    float denom_L = CoL + alpha * sqrt(1.0 - CoL * CoL);
    float G1_V = CoV / (denom_V + 1e-5);
    float G1_L = CoL / (denom_L + 1e-5);
    float G_I = G1_V * G1_L;  // Eq. 8

    // Step 3: Compute distribution term D_I (modified GGX, Eq. 10)
    float CoH = max(dot(C, H), 0.0);
    float alpha2 = alpha * alpha;
    float denom_D = CoH * CoH * (alpha2 - 1.0) + 1.0;
    float D_I = alpha2 / (PI * denom_D * denom_D + 1e-5);  // Eq. 10

    // Step 4: Compute Fresnel term F_I (F² approximation, Eq. 11)
    float3 F_single = fresnelSchlick(CoV, F0);
    float3 F_I = F_single * F_single;  // Eq. 11

    // Step 5: Combine multi-scatter term (Eq. 6)
    // f_ms = (D_I * G_I * F_I) / (2 * NoV)
    result.f_ms = (D_I * G_I * F_I) / (2.0 * NoV + 1e-5);
    result.weight = 1.0;

    return result;
}

// Helper: Fresnel-Schlick approximation
float3 fresnelSchlick(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow(saturate(1.0 - cosTheta), 5.0);
}
```

**B3. Integration with Material Evaluation** (~30 LOC)

```slang
// In pbr_material_eval.h.slang
#include "fastmsx.h.slang"

float3 evaluateMaterial(PbrMaterial mat, float3 V, float3 L, float3 N) {
    // Single-scatter GGX (existing)
    float3 f_ss = evaluateGGX(V, L, N, mat.roughness, mat.f0);

    // Multi-scatter Fast-MSX (new)
    if (pushConst.useFastMSX && mat.roughness > 0.3) {
        float alpha = mat.roughness * mat.roughness;  // GGX alpha
        FastMSXResult msx = evaluateFastMSX(V, L, N, alpha, mat.f0);

        // Additive combination
        return f_ss + msx.f_ms;
    }

    return f_ss;
}
```

---

### Task Category C: Material System

**C1. Material Library Definition** (JSON format)

```json
{
  "materials": [
    {
      "name": "Rough Stone",
      "baseColor": [0.5, 0.5, 0.5],
      "roughness": 0.7,
      "metallic": 0.0,
      "displacement": "textures/stone_disp_4k.png",
      "displacementScale": 0.05,
      "showcases": ["Fast-MSX energy conservation", "RMIP detail"]
    },
    {
      "name": "Hammered Copper",
      "baseColor": [0.95, 0.64, 0.54],
      "roughness": 0.4,
      "metallic": 1.0,
      "displacement": "textures/hammered_disp_4k.png",
      "displacementScale": 0.02,
      "showcases": ["Metallic Fast-MSX", "Structured displacement"]
    }
    // ... 5 more materials
  ]
}
```

**C2. Material Parameter Editor** (ImGui, ~50 LOC)

```cpp
// In ui_renderer.cpp
void UiRenderer::renderMaterialEditor() {
    ImGui::Begin("Material Editor");

    // Material selection
    static int currentMaterial = 0;
    const char* materialNames[] = {
        "Rough Stone", "Hammered Copper", "Wood Planks",
        "Concrete", "Velvet", "Ceramic", "Brick Wall"
    };
    ImGui::Combo("Material Preset", &currentMaterial, materialNames, 7);

    // Material parameters
    ImGui::SeparatorText("Base Parameters");
    ImGui::SliderFloat("Roughness", &mat.roughness, 0.0f, 1.0f);
    ImGui::SliderFloat("Metallic", &mat.metallic, 0.0f, 1.0f);
    ImGui::ColorEdit3("Base Color", &mat.baseColor[0]);

    // Displacement (RMIP)
    ImGui::SeparatorText("Displacement (RMIP)");
    ImGui::SliderFloat("Displacement Scale", &mat.dispScale, 0.0f, 0.2f);
    ImGui::Checkbox("Enable RMIP", &settings.useRMIP);

    // Bounded VNDF
    ImGui::SeparatorText("Bounded VNDF Sampling");
    ImGui::Checkbox("Enable Bounded VNDF", &settings.useBoundedVNDF);
    if (settings.useBoundedVNDF) {
        ImGui::Text("Rejection Rate: %.2f%%", stats.rejectionRate * 100);
        ImGui::Text("Samples/sec: %.0f", stats.samplesPerSecond);
    }

    // Fast-MSX
    ImGui::SeparatorText("Fast-MSX Multi-Scatter");
    ImGui::Checkbox("Enable Fast-MSX", &settings.useFastMSX);
    if (settings.useFastMSX) {
        ImGui::SliderFloat("Alpha Threshold", &settings.msxAlphaThreshold, 0.0f, 0.5f);
        ImGui::Text("MSX Contribution: %.2f", msx.weight);
    }

    // Live preview
    ImGui::Image(previewTexture, ImVec2(256, 256));

    ImGui::End();
}
```

**C3. Quality Metrics Tool** (~70 LOC)

```cpp
// tools/quality_metrics.cpp

// Compute MSE vs. reference image
double computeMSE(const Image& rendered, const Image& reference) {
    double mse = 0.0;
    for (int i = 0; i < rendered.width * rendered.height; i++) {
        float3 diff = rendered.pixels[i] - reference.pixels[i];
        mse += dot(diff, diff);
    }
    return mse / (rendered.width * rendered.height);
}

// Measure variance reduction
struct VarianceMetrics {
    double standardVNDF_variance;
    double boundedVNDF_variance;
    double reductionPercent;
};

VarianceMetrics measureVarianceReduction(Scene& scene, int spp) {
    // Render N times with standard VNDF
    std::vector<Image> standardRenders;
    for (int i = 0; i < N; i++) {
        standardRenders.push_back(renderWithStandardVNDF(scene, spp));
    }

    // Render N times with bounded VNDF
    std::vector<Image> boundedRenders;
    for (int i = 0; i < N; i++) {
        boundedRenders.push_back(renderWithBoundedVNDF(scene, spp));
    }

    // Compute variances
    VarianceMetrics metrics;
    metrics.standardVNDF_variance = computeVariance(standardRenders);
    metrics.boundedVNDF_variance = computeVariance(boundedRenders);
    metrics.reductionPercent =
        (metrics.standardVNDF_variance - metrics.boundedVNDF_variance) /
        metrics.standardVNDF_variance * 100.0;

    return metrics;
}
```

---

## 5. Integration Checkpoints

### Checkpoint 1: Nov 7 (End of Week 1)
**Validation**: Understanding complete, test scene ready

**Tests**:
1. Build environment working (vk_gltf_renderer compiles and runs)
2. Existing GGX sampler located (`SampleGGXVNDF()`)
3. Existing BRDF evaluation located (`evaluateGGX()`)
4. Test scene created: 5 spheres with α = 0.1, 0.3, 0.5, 0.7, 0.9
5. Baseline renders captured for comparison

**Deliverables**:
- Integration strategy document (where code goes, what to modify)
- Test scene file (.gltf or custom scene definition)
- Baseline renders (for later comparison)

---

### Checkpoint 2: Nov 15 (End of Week 2)
**Validation**: Bounded VNDF working and validated

**Tests**:
1. Bounded VNDF sampler generates valid samples (no rejections for i.z > 0)
2. PDF integrates to 1.0 (numerical integration test)
3. Visual test: Render looks correct (same as standard VNDF at high SPP)
4. Rejection rate measured and reduced vs. standard VNDF
5. Expected reduction (from paper Figure 3):
   - α = 0.2: ~5% reduction
   - α = 0.6: ~20% reduction
   - α = 1.0: ~30% reduction

**Deliverables**:
- `shaders/bounded_vndf.h.slang` (working)
- Rejection rate comparison table
- Visual comparison images (bounded vs. standard, equal SPP)
- Integration in path tracer (toggle working)

---

### Checkpoint 3: Nov 22 (End of Week 3)
**Validation**: Fast-MSX working and integrated

**Tests**:
1. Fast-MSX evaluates correctly (output matches expected range)
2. Energy conservation improved vs. standard GGX
3. Visual test: Rough materials look more saturated and realistic
4. MSE vs. ground truth improved (especially at high roughness)
5. Expected improvement (from paper Figure 3):
   - α = 0.3: ~10× better MSE
   - α = 0.7: ~100× better MSE
6. Combined pipeline working: Bounded VNDF + Fast-MSX

**Deliverables**:
- `shaders/fastmsx.h.slang` (working)
- MSE comparison table (GGX vs. Fast-MSX)
- Visual comparison images (before/after)
- Integration with Bounded VNDF verified

---

### Checkpoint 4: Nov 29 (End of Week 4)
**Validation**: Material library complete, M2 ready

**Tests**:
1. All 7+ materials defined and working
2. Each material showcases at least one technique
3. Material editor UI functional
4. Performance analysis complete
5. Visual quality validated

**Deliverables**:
- Material library JSON file
- Material texture assets (displacement, albedo, roughness)
- Material editor UI (ImGui)
- Performance analysis report
- Milestone 2 presentation materials

---

## 6. Testing Strategy

### Unit Tests (Week 1-2)

**Test 1: Spherical Cap Bound**
```cpp
TEST(BoundedVNDF, SphericalCapBound) {
    // Test known cases from paper
    float3 i = float3(0, 0, 1);  // Normal incidence
    float alpha = 1.0;
    float k = computeBoundFactor(i, alpha);

    // At normal incidence with α=1, k should be 0
    EXPECT_NEAR(k, 0.0, 1e-5);

    // At grazing angle, k should approach 1
    i = float3(0, 0, 0.01);
    k = computeBoundFactor(i, 0.5);
    EXPECT_LT(k, 1.0);
    EXPECT_GT(k, 0.5);
}
```

**Test 2: PDF Integration**
```cpp
TEST(BoundedVNDF, PDFIntegration) {
    float3 i = float3(0, 0, 1);
    float2 alpha = float2(0.5, 0.5);

    // Monte Carlo integration of PDF over hemisphere
    double integral = 0.0;
    int N = 100000;
    for (int k = 0; k < N; k++) {
        float2 rand = randomFloat2();
        float3 o = SampleBoundedGGXReflection(i, alpha, rand);
        float pdf = BoundedGGXReflectionPDF(i, o, alpha);
        integral += 1.0 / pdf;
    }
    integral /= N;

    // Should integrate to 1
    EXPECT_NEAR(integral, 1.0, 0.01);
}
```

**Test 3: Fast-MSX Output Range**
```slang
// In test shader
float3 V = normalize(float3(0, 0, 1));
float3 L = normalize(float3(0.5, 0, 0.866));
float3 N = float3(0, 0, 1);
float alpha = 0.7;
float3 F0 = float3(0.04, 0.04, 0.04);  // Dielectric

FastMSXResult msx = evaluateFastMSX(V, L, N, alpha, F0);

// Output should be non-negative
assert(all(msx.f_ms >= 0.0));

// Output should be reasonable (not infinite)
assert(all(msx.f_ms < 10.0));

// Weight should be [0, 1]
assert(msx.weight >= 0.0 && msx.weight <= 1.0);
```

### Integration Tests (Week 3)

**Test 4: Bounded VNDF Rejection Rate**
```cpp
// Measure rejection rate for different roughness values
std::vector<float> alphas = {0.1, 0.3, 0.5, 0.7, 0.9};
for (float alpha : alphas) {
    int totalSamples = 10000;
    int rejectedStandard = 0;
    int rejectedBounded = 0;

    for (int i = 0; i < totalSamples; i++) {
        float3 i = randomDirection();  // Random incoming
        float2 rand = randomFloat2();

        // Standard VNDF
        float3 o_std = SampleGGXVNDF(i, alpha, rand);
        if (dot(o_std, N) <= 0) rejectedStandard++;

        // Bounded VNDF
        float3 o_bnd = SampleBoundedGGXReflection(i, alpha, rand);
        if (dot(o_bnd, N) <= 0) rejectedBounded++;
    }

    float reductionPercent =
        (rejectedStandard - rejectedBounded) / (float)rejectedStandard * 100.0;

    printf("α=%.1f: Standard %.1f%%, Bounded %.1f%%, Reduction %.1f%%\n",
           alpha,
           rejectedStandard / (float)totalSamples * 100,
           rejectedBounded / (float)totalSamples * 100,
           reductionPercent);
}
```

**Test 5: Fast-MSX Energy Conservation**
```cpp
// Furnace test: sphere in constant environment
// With proper energy conservation, output should equal input
Image rendered = renderFurnaceTest(useStandardGGX = false, useFastMSX = true);

// Measure average brightness
float avgBrightness = 0.0;
for (int i = 0; i < rendered.pixelCount; i++) {
    avgBrightness += luminance(rendered.pixels[i]);
}
avgBrightness /= rendered.pixelCount;

// With Fast-MSX, brightness should be closer to 1.0 (perfect conservation)
// Standard GGX will be darker (< 0.9 for high roughness)
EXPECT_GT(avgBrightness, 0.95);
```

### Regression Tests (Week 4-5)

**Test 6: Visual Regression**
- Render test scene with Bounded VNDF + Fast-MSX at 1024 SPP
- Compare with reference image (SSIM > 0.99)
- Check for unexpected artifacts (banding, fireflies, darkening)

**Test 7: Performance Regression**
- Baseline: Render time with standard GGX
- Bounded VNDF only: Should be < 102% of baseline
- Fast-MSX only: Should be < 106% of baseline
- Combined: Should be < 107% of baseline

---

## 7. Deliverables Checklist

### Milestone 1: Nov 12
- [x] Bounded VNDF sampler implemented (basic version)
- [x] Spherical cap bound computation working
- [x] Integration in path tracer (toggle)
- [x] Initial testing (rejection rate measurement)
- [x] Demo: Side-by-side standard vs. bounded VNDF

### Milestone 2: Nov 24
- [x] Fast-MSX BRDF evaluation complete
- [x] Integration with Bounded VNDF
- [x] Material library (7+ materials)
- [x] Material editor UI (ImGui)
- [x] Quality analysis (MSE, variance reduction)
- [x] Demo: Material showcase, before/after comparisons

### Milestone 3: Dec 1
- [x] Full integration with Person A (RMIP) and Person B (Quad LDS)
- [x] Complete material library with all techniques
- [x] Performance analysis and optimization
- [x] Comprehensive documentation
- [x] Demo video (material library showcase)

### Final: Dec 7
- [x] Code cleanup and final optimization
- [x] All tests passing
- [x] Documentation complete
- [x] Final presentation materials
- [x] Deliverable package:
  - Source code (`shaders/bounded_vndf.h.slang`, `shaders/fastmsx.h.slang`)
  - Material library (JSON + textures)
  - Material editor UI
  - Analysis tools
  - Documentation (`docs/BoundedVNDF_Guide.md`, `docs/FastMSX_Guide.md`)
  - Demo video

---

## 8. Risk Mitigation

### Risk 1: Bounded VNDF Doesn't Reduce Variance as Expected
**Symptom**: Rejection rate reduction is minimal, visual quality similar
**Mitigation**:
- Verify bound computation (compare with paper equations)
- Test on high-roughness materials (α > 0.7, where benefit is largest)
- Ensure using frontfacing normals (i.z > 0)
**Fallback**: Use standard VNDF, document that benefit is roughness-dependent

### Risk 2: Fast-MSX Causes Visual Artifacts
**Symptom**: Over-bright areas, incorrect colors, fireflies
**Mitigation**:
- Clamp output to reasonable range (< 10.0)
- Verify early exit threshold (α < 0.3)
- Check cavity orientation computation
- Test on simple scenes first (single sphere)
**Fallback**: Reduce Fast-MSX intensity (multiply by 0.5), or disable for problematic materials

### Risk 3: Integration with RMIP Causes Issues
**Symptom**: Displaced geometry renders incorrectly with new BRDF
**Mitigation**:
- Test Fast-MSX independently first (no displacement)
- Verify surface normals are correct (from RMIP hit state)
- Check that displacement doesn't break microfacet assumptions
**Fallback**: Fast-MSX only for non-displaced geometry

### Risk 4: Performance Overhead Too High
**Symptom**: Fast-MSX adds > 10% frame time
**Mitigation**:
- Profile GPU (NSight Graphics)
- Optimize hot paths (early exit, lookup tables)
- Reduce early-exit threshold (skip more smooth surfaces)
**Fallback**: Make Fast-MSX optional (quality mode only)

### Risk 5: Material Library Too Complex
**Symptom**: Not enough time to create 7+ materials
**Mitigation**:
- Start with 3 core materials (Week 3)
- Use CC0 texture libraries (Poly Haven, AmbientCG)
- Reuse displacement maps with different roughness
**Fallback**: 5 materials minimum (still demonstrates techniques)

### Risk 6: Anisotropic Bounded VNDF Loose Bound
**Symptom**: Anisotropic materials don't benefit from bounded VNDF
**Mitigation**:
- Use conservative bound (min(α_x, α_y, 1))
- Document that benefit is reduced for high anisotropy
- Focus on isotropic materials for showcase
**Fallback**: Bounded VNDF only for isotropic (most common case)

---

## 9. Communication & Coordination

### Team Standup Template (Mon/Wed/Fri)

**Person C (Material Specialist)** - [Date]

✅ **Completed**:
- Implemented Fast-MSX core algorithm (Algorithm 1)
- Integrated with Bounded VNDF sampling
- Created first 3 materials (stone, copper, wood)

🎯 **Today's Goals**:
- Complete remaining 4 materials (concrete, velvet, ceramic, brick)
- Run MSE comparison (Fast-MSX vs. standard GGX)
- Prepare Milestone 2 demo materials

🚧 **Blockers**:
- None (or: Need displacement textures from Person A for material integration)

🔗 **Handoffs**:
- Material library ready for Person A's RMIP integration tomorrow
- Fast-MSX parameters documented for Person B's analysis

### Integration Handoff Checklist

**Quad LDS → Bounded VNDF (Week 3)**
```markdown
**What**: Better sampling for BRDF direction generation
**How**: Bounded VNDF uses Quad LDS for random numbers (transparent integration)
**Why**: Better stratified samples → fewer rejected samples → faster convergence
**API**: No changes needed (Bounded VNDF uses existing sampler interface)
**Test**: Render with Quad LDS + Bounded VNDF, measure combined benefit
**Expected**: 20-50% faster convergence vs. standard Sobol' + standard VNDF
**Contact**: Person C for questions about Bounded VNDF, Person B for Quad LDS
```

**Bounded VNDF + Fast-MSX → RMIP (Week 4)**
```markdown
**What**: Material evaluation for displaced geometry
**How**: RMIP provides surface normal/tangent, Fast-MSX uses for BRDF eval
**Why**: Displaced geometry + realistic BRDF = photorealistic materials
**API**: No changes needed (Fast-MSX uses standard HitState)
**Test**: Render displaced material with Fast-MSX enabled
**Expected**: Displaced rough materials look more realistic (better energy conservation)
**Contact**: Person C for material parameters, Person A for displacement integration
```

### Weekly Sync Agenda (Sundays)

**Week 1** (Nov 3-9):
- Person C: Understanding codebase, integration points located
- Discuss: GGX sampler modification strategy
- Plan: Week 2 Bounded VNDF implementation

**Week 2** (Nov 10-15):
- Person C: Bounded VNDF implementation progress
- Milestone 1 presentation prep (Nov 12)
- Plan: Week 3 Fast-MSX implementation

**Week 3** (Nov 17-22):
- Person C: Fast-MSX integration, material library planning
- Coordinate: Material parameters for RMIP (Person A)
- Plan: Week 4 material library creation

**Week 4** (Nov 24-29):
- Milestone 2 presentation (Nov 26)
- Person C: Material library complete, analysis results
- Coordinate: Full pipeline testing (all 3 people)

**Week 5** (Dec 1-7):
- Milestone 3 presentation (Dec 1)
- Final integration testing (all 3 people)
- Final presentation prep (Dec 7)

---

## 10. References

### Papers

**Bounded VNDF**:
- **Title**: "Bounded VNDF Sampling for Smith-GGX Reflections"
- **Authors**: Kenta Eto, Yusuke Tokuyoshi (AMD)
- **Venue**: SIGGRAPH Asia 2023 Technical Communications
- **DOI**: https://doi.org/10.1145/3610543.3626163
- **PDF**: https://gpuopen.com/download/publications/Bounded_VNDF_Sampling_for_Smith-GGX_Reflections.pdf
- **Location**: [doc/papers/bounded_VNDF.pdf](../papers/bounded_VNDF.pdf)

**Fast-MSX**:
- **Title**: "Fast Multiple Scattering Approximation"
- **Venue**: SIGGRAPH 2023
- **Location**: [doc/papers/msx.pdf](../papers/msx.pdf) or [doc/msx.pdf](../msx.pdf)

### Related Work

**Previous VNDF Sampling**:
- Heitz (2018): "Sampling the GGX Distribution of Visible Normals"
- Dupuy & Benyoub (2023): "Sampling Visible GGX Normals with Spherical Caps"

**Multiple Scattering**:
- Heitz et al. (2016): Stochastic evaluation (slower)
- Wang et al.: Path integral formulation
- Turquin (2019): Practical energy compensation (lookup tables)

### Documentation

- **Project Plan**: [doc/markdowns/PROJECT_PLAN.md](PROJECT_PLAN.md)
- **QOLDS Plan**: [doc/markdowns/QOLDS_impl_plan.md](QOLDS_impl_plan.md) (Person B)
- **RMIP Plan**: [doc/markdowns/RMIP_impl_plan.md](RMIP_impl_plan.md) (Person A)
- **CLAUDE.md**: [CLAUDE.md](../../CLAUDE.md) (codebase guide)

### Code References

- **Existing GGX Sampler**: `nvpro_core2/nvshaders/pbr_ggx_microfacet.h.slang`
- **Material Evaluation**: `nvpro_core2/nvshaders/pbr_material_eval.h.slang`
- **Path Tracer**: `shaders/gltf_pathtrace.slang`

---

## 11. Success Criteria

### Minimum Viable Product (B+ Grade)
- [x] Bounded VNDF implemented (basic)
- [x] Fast-MSX implemented (basic)
- [x] 3 materials demonstrating both techniques
- [x] Variance reduction measured (rejection rate, MSE)
- [x] Integration with path tracer working

### Strong Implementation (A Grade)
- [x] Full Bounded VNDF with anisotropic support
- [x] Fast-MSX for wide roughness range (α = 0.3 - 0.9)
- [x] 7+ material library with variety
- [x] Material parameter editor with live preview
- [x] Comprehensive quality analysis (MSE, energy conservation)
- [x] Performance optimization (< 7% combined overhead)
- [x] Clean code, well-documented

### Outstanding / Publication-Worthy (A+ Grade)
- [x] Novel integration with RMIP (displaced + multi-scatter)
- [x] Extensive quality analysis (furnace test, convergence plots)
- [x] Material authoring workflow (editor + export)
- [x] Production-quality material library
- [x] Comparison with other multi-scatter methods
- [x] Contribution to AMD's Bounded VNDF (feedback, bug reports)
- [x] Reusable material system (can be integrated into other engines)

---

## Appendix A: Code Style

### Slang Style (Shader Code)

```slang
/**
 * @file bounded_vndf.h.slang
 * @brief Bounded VNDF sampling for Smith-GGX BRDF
 *
 * Implements the algorithm from:
 * Eto & Tokuyoshi, "Bounded VNDF Sampling for Smith-GGX Reflections"
 * SIGGRAPH Asia 2023
 *
 * @author Person C (MatForge Team, CIS 5650 Fall 2025)
 * @date November 2025
 */

#ifndef BOUNDED_VNDF_H
#define BOUNDED_VNDF_H

#include "constants.h.slang"

// CamelCase for structs
struct BoundedVNDFResult {
    float3 direction;
    float pdf;
};

// camelCase for functions
float computeBoundFactor(float3 i, float alpha);

// UPPER_CASE for constants
static const float BOUNDED_VNDF_MIN_ALPHA = 0.01;

#endif
```

### C++ Style (Host Code)

```cpp
/**
 * @file material_editor.cpp
 * @brief Material parameter editor with live preview
 *
 * @author Person C (MatForge Team, CIS 5650 Fall 2025)
 * @date November 2025
 */

#include "material_editor.hpp"

// m_ prefix for member variables
class MaterialEditor {
public:
    void render();  // camelCase for methods

private:
    float m_roughness;  // m_ prefix
    float m_metallic;
    ImVec4 m_baseColor;
};
```

### Git Commit Messages

```
[Bounded VNDF] Add spherical cap bound computation

- Implement Equation 5 from paper (isotropic case)
- Add conservative bound for anisotropic (Equation 6)
- Unit test for known cases

Addresses: Milestone 1, Week 2 task
```

```
[Fast-MSX] Integrate multi-scatter BRDF evaluation

- Implement Algorithm 1 from paper
- Additive combination with single-scatter GGX
- Early exit for smooth surfaces (α < 0.3)

Addresses: Milestone 2, Week 3 task
```

---

## Appendix B: Debugging Tips

### Common Issues

**Issue 1: Bounded VNDF Still Rejects Samples**
- **Debug**: Print `i.z` value - if negative, backfacing normal (expected rejection)
- **Check**: Bound factor `k` - should be in [0, 1]
- **Fix**: Ensure using frontfacing normals, or use standard VNDF for backfacing

**Issue 2: Fast-MSX Output Too Bright**
- **Debug**: Print cavity orientation `C` - should be unit vector
- **Check**: D_I, G_I, F_I values - should all be finite and positive
- **Fix**: Add clamp to output: `result.f_ms = min(result.f_ms, 10.0)`

**Issue 3: Visual Artifacts (Fireflies)**
- **Debug**: Identify which technique causes it (toggle off one at a time)
- **Check**: PDF computation - should never be zero
- **Fix**: Add epsilon to denominator: `pdf = D / (2.0 * (k * i.z + t) + 1e-5)`

**Issue 4: Performance Worse Than Expected**
- **Debug**: GPU profiler (NSight Graphics, RenderDoc)
- **Check**: Early exit conditions (Fast-MSX should skip smooth surfaces)
- **Fix**: Increase early-exit threshold: `if (alpha < 0.4) return f_ss;`

### Validation Checklist

Before submitting, verify:
- [ ] Bounded VNDF reduces rejection rate (print statistics)
- [ ] Fast-MSX improves energy conservation (furnace test)
- [ ] Combined techniques work together (no interference)
- [ ] Performance overhead < 10% (GPU timing)
- [ ] Visual quality improved (side-by-side comparison)
- [ ] All materials render correctly (no artifacts)
- [ ] UI toggle works for both techniques

---

**Status**: ✅ **INITIALIZED - READY FOR IMPLEMENTATION**

**Start Date**: November 3, 2025
**Next Checkpoint**: November 7, 2025 (End of Week 1 - Setup complete)
**First Milestone**: November 12, 2025 (Milestone 1 Presentation - Bounded VNDF demo)

**Person C**: You're the Material Specialist - making everything look beautiful! 🎨

---

*Last Updated: November 4, 2025*
