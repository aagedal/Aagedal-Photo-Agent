#include <metal_stdlib>
using namespace metal;

struct EditParams {
    float exposure;          // EV (legacy field, baked into LUT when LUT is active)
    float vibrance;          // -1..1
    float saturation;        // 0..2 (1=identity)
    float pad0;              // alignment padding

    float3x3 whiteBalanceMatrix; // Bradford chromatic adaptation (identity if no WB)

    uint activeFlags;        // bitmask: bit0=toneLUT, bit1=vibrance,
                             // bit2=saturation, bit3=whiteBalance
    uint _pad1;              // align to 8 bytes for float2

    float2 scale;            // source→drawable scale (stretch-to-fill)
    float2 sourceSize;       // source texture dimensions
    float2 drawableSize;     // output drawable dimensions

    float lutDomainMin;      // -0.5 (extended range for color matrix overshoot)
    float lutDomainMax;      // 4.0 (HDR headroom)
};

kernel void editAdjustments(
    texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    texture1d<float, access::sample> toneLUT [[texture(2)]],
    constant EditParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.drawableSize.x) || gid.y >= uint(params.drawableSize.y)) {
        return;
    }

    // Map drawable pixel to source texture coordinate (stretch-to-fill)
    float2 sourceCoord = float2(gid) / params.scale;

    // Normalize to [0,1] for sampling
    float2 uv = sourceCoord / params.sourceSize;

    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    half4 color = source.sample(bilinear, uv);
    half3 rgb = color.rgb;

    // 1. White Balance (3x3 matrix) — chromatic adaptation before tonal (matches ACR)
    if (params.activeFlags & (1u << 3)) {
        float3 rgbF = float3(rgb);
        rgbF = params.whiteBalanceMatrix * rgbF;
        rgb = half3(rgbF);
    }

    // 2. Tone LUT — per-channel lookup replacing exposure + all tonal operations.
    //    The 1D LUT bakes Exposure, Contrast, Blacks, Shadows, Highlights, Whites
    //    into a single texture lookup per channel.
    if (params.activeFlags & (1u << 0)) {
        float range = params.lutDomainMax - params.lutDomainMin;
        constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);

        float ur = (float(rgb.r) - params.lutDomainMin) / range;
        float ug = (float(rgb.g) - params.lutDomainMin) / range;
        float ub = (float(rgb.b) - params.lutDomainMin) / range;

        rgb.r = half(toneLUT.sample(lutSampler, ur).r);
        rgb.g = half(toneLUT.sample(lutSampler, ug).r);
        rgb.b = half(toneLUT.sample(lutSampler, ub).r);
    }

    // 3. Vibrance: selective saturation boost on less-saturated pixels
    if (params.activeFlags & (1u << 1)) {
        half lum = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
        half maxC = max3(rgb.r, rgb.g, rgb.b);
        half minC = min3(rgb.r, rgb.g, rgb.b);
        half sat = (maxC > (half)0.001) ? ((maxC - minC) / maxC) : (half)0.0;
        half boost = (half)params.vibrance * ((half)1.0 - sat);
        rgb = mix(half3(lum), rgb, (half)1.0 + boost);
    }

    // 4. Saturation — exact match to CIColorControls saturation
    if (params.activeFlags & (1u << 2)) {
        half lum = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
        rgb = mix(half3(lum), rgb, (half)params.saturation);
    }

    destination.write(half4(rgb, color.a), gid);
}
