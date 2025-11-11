#include "nvshaders/bsdf_functions.h.slang"
#include "nvshaders/pbr_ggx_microfacet.h.slang"

float3 compute_fast_msx(PbrMaterial mat, float3 v, float3 l, float3 n)
{


    // G_I Term
    float3 h = normalize(l + v);

    float3 c = normalize(h + n);
    float theta_vc = acos(clampedDot(c, v));
    float theta_vl = acos(clampedDot(v, l));
    float theta_m = (M_PI - theta_vl) * 0.25;

    float OP = sin(theta_vc - theta_m) / sin(theta_vc + theta_m);
    float G_I = 1.0 - max(0.0, OP);


    // D_I
    float alphax = mat.roughness.x;
    float alphay = mat.roughness.y;
    
    float alphaxy = alphax * alphay;
    float cos_theta_m = cos(theta_m);
    float cos_theta_m_2 = cos_theta_m * cos_theta_m;
    float denom = (cos_theta_m_2 * (alphaxy - 1.0) + 1.0);
    float D_I = (alphaxy * M_1_PI) / (denom * denom);  

    float3 f0 = lerp(float3(0.04), mat.baseColor, mat.metallic); 
    float3 F_direct = schlickFresnel(f0, float3(1.0), dot(v, h));
    float3 F_I = F_direct * F_direct;

    float c_dot_v = clampedDot(c, v);
    if (c_dot_v < 0.0001) return float3(0.0);

    float3 f_sI = (D_I * G_I * F_I) / (2.0 * c_dot_v);

    return f_sI;
}

void bsdfEvaluate_new(inout BsdfEvaluateData data, PbrMaterial mat, bool useFastMSX)
{
    bsdfEvaluate(data, mat);

    bool isGlossyLobe = (data.bsdf_glossy.x > 0.0 || data.bsdf_glossy.y > 0.0 || data.bsdf_glossy.z > 0.0);

    if (useFastMSX && isGlossyLobe && data.pdf > 0.0)
    {
        float nk2 = abs(dot(data.k2, mat.N));
        if (nk2 > 0.0001)
        {
            float3 f_sI = compute_fast_msx(mat, data.k1, data.k2, mat.N);

            float3 f_sI_times_cos = f_sI * nk2;

            data.bsdf_glossy += f_sI_times_cos;
        }
    }
}    