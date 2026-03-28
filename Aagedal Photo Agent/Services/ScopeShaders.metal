#include <metal_stdlib>
using namespace metal;

// ============================================================
// EditParams — must match Swift EditParams and EditAdjustments.metal exactly
// ============================================================

struct ScopeEditParams {
    float exposure;
    float vibrance;
    float saturation;
    uint gamutClipMode;      // 0=off (unused by scopes, kept for struct layout match)

    float3x3 whiteBalanceMatrix;

    uint activeFlags;    // bit0=toneLUT, bit1=vibrance, bit2=saturation, bit3=whiteBalance, bit4=hdrMode
    uint maskCount;

    float2 scale;
    float2 sourceSize;
    float2 drawableSize;

    float lutDomainMin;
    float lutDomainMax;
};

// ============================================================
// MaskParams — must match Swift MaskParams and EditAdjustments.metal exactly
// ============================================================

struct MaskParams {
    float2 center;          // normalized [0,1] in image UV space
    float2 radii;           // normalized radii
    float rotation;         // radians
    float feather;          // 0-1 (normalized from 0-100 on CPU side)
    float inverted;         // 0 or 1
    float amount;           // 0-1 overall strength

    float exposure;         // EV delta
    float contrast;         // -1..1
    float highlights;       // -1..1 (not yet implemented)
    float shadows;          // -1..1 (not yet implemented)
    float whites;           // -1..1 (not yet implemented)
    float blacks;           // -1..1 (not yet implemented)
    float saturation;       // 0..2 (1=identity)
    float vibrance;         // -1..1
    uint  activeFlags;      // bitmask: bit0=exposure, bit1=contrast,
                            // bit2=highlights, bit3=shadows, bit4=whites,
                            // bit5=blacks, bit6=saturation, bit7=vibrance
    uint  _pad;
};

// ============================================================
// ScopeParams — matches Swift ScopeParams struct
// ============================================================

struct ScopeParams {
    uint outputWidth;
    uint outputHeight;
    uint dataWidth;
    uint levels;
    uint labelMargin;
    uint verticalMargin;
    uint sampleWidth;
    uint sampleHeight;
    uint scaleMode;       // 0=percentage, 1=nits
    uint channelCount;
    uint channelWidth;
    uint channelGap;
    float cropLeft;       // Normalized crop region [0..1]
    float cropTop;
    float cropRight;
    float cropBottom;
    uint clipMode;        // 0=unclipped, 1=clipped
    uint targetGamut;     // 0=sRGB, 1=displayP3, 2=rec2020, 3=adobeRGB
    uint displayGamut;    // gamut index for display capability indicator (same encoding)
};

// ============================================================
// Nits scale conversion (matches WaveformScale in Swift)
// ============================================================

constant float sdrWhiteNits = 203.0;
constant float maxNits = 2000.0;
constant float logK = 0.1;
constant float logDenom = 2.3032; // log10(1 + 2000 * 0.1)

inline float nitsFraction(float n) {
    if (n <= 0) return 0;
    return log10(1.0 + n * logK) / logDenom;
}

inline float linearToFraction(float linear) {
    float n = linear * sdrWhiteNits;
    return nitsFraction(min(n, maxNits));
}

// ============================================================
// Linear → sRGB gamma encoding
// The CPU scope path receives gamma-encoded sRGB pixels (CGImage drawn
// into an sRGB CGContext). The Metal path works in linear light, so we
// must apply the sRGB transfer function before binning to match.
// ============================================================

inline float linearToSRGB(float x) {
    if (x <= 0.0031308)
        return 12.92 * x;
    else
        return 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}

// ============================================================
// Apply edit adjustments (same logic as editAdjustments kernel)
// ============================================================

inline float3 applyEdits(
    float3 rgb,
    float2 uv,
    constant ScopeEditParams &params,
    texture1d<float, access::sample> toneLUT,
    constant MaskParams *masks)
{
    // 1. White Balance
    if (params.activeFlags & (1u << 3)) {
        rgb = params.whiteBalanceMatrix * rgb;
    }

    // 2. Tone LUT
    if (params.activeFlags & (1u << 0)) {
        float range = params.lutDomainMax - params.lutDomainMin;
        constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);
        float ur = (rgb.r - params.lutDomainMin) / range;
        float ug = (rgb.g - params.lutDomainMin) / range;
        float ub = (rgb.b - params.lutDomainMin) / range;
        float4 rS = toneLUT.sample(lutSampler, ur);
        float4 gS = toneLUT.sample(lutSampler, ug);
        float4 bS = toneLUT.sample(lutSampler, ub);
        rgb = float3(rS.r, gS.g, bS.b);
        // Highlight desaturation — HDR-aware thresholds (mirrors EditAdjustments.metal)
        float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        bool isHDR = (params.activeFlags & (1u << 4)) != 0;
        float desatLow  = isHDR ? 1.5  : 0.55;
        float desatHigh = isHDR ? 4.0  : 1.3;
        float desatMax  = isHDR ? 0.5  : 0.7;
        float desat = smoothstep(desatLow, desatHigh, lum) * desatMax;
        rgb = mix(rgb, float3(lum), desat);
    }

    // 3. Vibrance
    if (params.activeFlags & (1u << 1)) {
        float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float maxC = max3(rgb.r, rgb.g, rgb.b);
        float minC = min3(rgb.r, rgb.g, rgb.b);
        float sat = (maxC > 0.001) ? ((maxC - minC) / maxC) : 0.0;
        float boost = params.vibrance * (1.0 - sat);
        rgb = mix(float3(lum), rgb, 1.0 + boost);
    }

    // 4. Saturation
    if (params.activeFlags & (1u << 2)) {
        float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(lum), rgb, params.saturation);
    }

    // 5. Local mask adjustments — mirrors EditAdjustments.metal
    for (uint m = 0; m < params.maskCount && m < 8; m++) {
        constant MaskParams &mask = masks[m];

        float cosR = cos(mask.rotation);
        float sinR = sin(mask.rotation);
        float2 d = uv - mask.center;
        float2 local = float2(d.x * cosR + d.y * sinR, -d.x * sinR + d.y * cosR);
        float dist = length(local / mask.radii);
        float inner = 1.0 - mask.feather;
        float weight = 1.0 - smoothstep(inner, 1.0, dist);
        if (mask.inverted > 0.5) weight = 1.0 - weight;
        weight *= mask.amount;
        if (weight < 0.001) continue;

        float3 adjusted = rgb;

        // Exposure: multiplicative EV shift
        if (mask.activeFlags & (1u << 0)) {
            adjusted *= exp2(mask.exposure);
        }
        // Contrast: ACR parametric sigmoid — gain peaks at midtones, falls at extremes
        if (mask.activeFlags & (1u << 1)) {
            for (int c = 0; c < 3; c++) {
                float x = adjusted[c];
                float centered = x - 0.5;
                float falloff = min(4.0 * centered * centered, 1.0);
                float gain = 1.0 + mask.contrast * 0.7 * (1.0 - falloff);
                adjusted[c] = 0.5 + centered * max(gain, 0.1f);
            }
        }
        // Blacks: tapered shadow-region adjustment in sqrt-space
        if (mask.activeFlags & (1u << 5)) {
            for (int c = 0; c < 3; c++) {
                float x = adjusted[c];
                float px = sqrt(max(0.0, x));
                float boundary = mask.blacks < 0 ? 0.50 : 0.35;
                float amplitude = mask.blacks < 0 ? 0.14 : 0.10;
                float shadowRegion = max(0.0, 1.0 - px / boundary);
                float delta = mask.blacks * amplitude * shadowRegion;
                float pxNew = max(0.0, px + delta);
                adjusted[c] = pxNew * pxNew;
            }
        }
        // Shadows: Gaussian-weighted lift in sqrt-space
        if (mask.activeFlags & (1u << 3)) {
            for (int c = 0; c < 3; c++) {
                float x = adjusted[c];
                float px = sqrt(max(0.0, x));
                float ctr = 0.15;
                float w = 0.15;
                float d = (px - ctr) / w;
                float delta = mask.shadows * 0.08 * exp(-0.5 * d * d);
                float pxNew = max(0.0, px + delta);
                adjusted[c] = pxNew * pxNew;
            }
        }
        // Highlights: one-sided ramp for upper tones
        if (mask.activeFlags & (1u << 2)) {
            float knee = 0.15;
            for (int c = 0; c < 3; c++) {
                float x = adjusted[c];
                if (x > knee) {
                    float t = min((x - knee) / 0.85, 1.0);
                    float wt = t * t * (3.0 - 2.0 * t) * (1.0 - t * t * 0.3);
                    adjusted[c] = x + mask.highlights * 0.30 * wt;
                }
            }
        }
        // Whites: upper tone range adjustment
        if (mask.activeFlags & (1u << 4)) {
            float knee = 0.45;
            for (int c = 0; c < 3; c++) {
                float x = adjusted[c];
                if (x > knee) {
                    float t = (x - knee) / (1.0 - knee);
                    float tClamped = min(t, 2.0);
                    if (mask.whites > 0) {
                        float wt = tClamped * (2.0 - tClamped);
                        x += mask.whites * 1.2 * wt;
                    } else {
                        float pull = sqrt(tClamped) * 0.25;
                        x -= abs(mask.whites) * pull * (1.0 - knee);
                    }
                    adjusted[c] = x;
                }
            }
        }
        // Saturation
        if (mask.activeFlags & (1u << 6)) {
            float lum = dot(adjusted, float3(0.2126, 0.7152, 0.0722));
            adjusted = mix(float3(lum), adjusted, mask.saturation);
        }
        // Vibrance: selective saturation boost
        if (mask.activeFlags & (1u << 7)) {
            float lum = dot(adjusted, float3(0.2126, 0.7152, 0.0722));
            float maxC = max3(adjusted.r, adjusted.g, adjusted.b);
            float minC = min3(adjusted.r, adjusted.g, adjusted.b);
            float sat = (maxC > 0.001) ? ((maxC - minC) / maxC) : 0.0;
            float boost = mask.vibrance * (1.0 - sat);
            adjusted = mix(float3(lum), adjusted, 1.0 + boost);
        }

        rgb = mix(rgb, adjusted, weight);
    }

    return rgb;
}

// ============================================================
// Waveform Accumulate
// ============================================================

kernel void waveformAccumulate(
    texture2d<half, access::sample> source [[texture(0)]],
    texture1d<float, access::sample> toneLUT [[texture(1)]],
    device atomic_uint *bins [[buffer(0)]],
    constant ScopeEditParams &editParams [[buffer(1)]],
    constant ScopeParams &scopeParams [[buffer(2)]],
    constant MaskParams *masks [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= scopeParams.sampleWidth || gid.y >= scopeParams.sampleHeight) return;

    // Remap UV from sample grid to crop region within source texture
    float2 uv = (float2(gid) + 0.5) / float2(scopeParams.sampleWidth, scopeParams.sampleHeight);
    uv = float2(scopeParams.cropLeft, scopeParams.cropTop)
       + uv * float2(scopeParams.cropRight - scopeParams.cropLeft,
                      scopeParams.cropBottom - scopeParams.cropTop);

    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    half4 color = source.sample(bilinear, uv);
    float3 rgb = float3(color.rgb);
    rgb = applyEdits(rgb, uv, editParams, toneLUT, masks);

    int levels = int(scopeParams.levels);
    int level;
    if (scopeParams.scaleMode == 1) {
        // Nits mode: use raw linear values — NO saturate() clamping.
        // linearToFraction() maps to [0, 1] via logarithmic nits scale with 10000-nit cap.
        float lumaLinear = dot(max(rgb, float3(0)), float3(0.2126, 0.7152, 0.0722));
        level = clamp(int(linearToFraction(lumaLinear) * float(levels - 1)), 0, levels - 1);
    } else {
        // Percentage mode: clamp to SDR range as before
        float rGamma = linearToSRGB(saturate(rgb.r));
        float gGamma = linearToSRGB(saturate(rgb.g));
        float bGamma = linearToSRGB(saturate(rgb.b));
        float luma = 0.2126 * rGamma + 0.7152 * gGamma + 0.0722 * bGamma;
        level = clamp(int(luma * float(levels - 1)), 0, levels - 1);
    }

    // Color bin accumulation: always clamped to SDR for display coloring
    float r = linearToSRGB(saturate(rgb.r));
    float g = linearToSRGB(saturate(rgb.g));
    float b = linearToSRGB(saturate(rgb.b));

    int x = int(gid.x);
    uint binCount = scopeParams.dataWidth * scopeParams.levels;
    uint idx = uint(x * levels + level);

    atomic_fetch_add_explicit(&bins[idx], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[binCount + idx], uint(r * 255.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[2 * binCount + idx], uint(g * 255.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[3 * binCount + idx], uint(b * 255.0), memory_order_relaxed);
}

// ============================================================
// Waveform Render
// ============================================================

kernel void waveformRender(
    texture2d<half, access::write> output [[texture(0)]],
    device uint *bins [[buffer(0)]],
    constant ScopeParams &params [[buffer(1)]],
    constant uint &maxCount [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint outW = params.outputWidth;
    uint outH = params.outputHeight;
    if (gid.x >= outW || gid.y >= outH) return;

    uint binCount = params.dataWidth * params.levels;

    // Label margin area — black
    if (gid.x < params.labelMargin) {
        output.write(half4(0, 0, 0, 1), gid);
        return;
    }

    uint dataX = gid.x - params.labelMargin;
    if (dataX >= params.dataWidth) {
        output.write(half4(0, 0, 0, 1), gid);
        return;
    }

    uint vm = params.verticalMargin;
    int dataHeight = int(outH) - int(vm * 2);
    int fromBottom = int(outH) - 1 - int(gid.y);

    // Outside data area — black
    if (fromBottom < int(vm) || fromBottom > int(vm) + dataHeight) {
        output.write(half4(0, 0, 0, 1), gid);
        return;
    }

    // Guide lines
    float3 guideColor = float3(0);
    if (params.scaleMode == 0) {
        // Percentage guides at 0%, 25%, 50%, 75%, 100%
        for (int i = 0; i <= 4; i++) {
            float fraction = float(i) * 0.25;
            int guideFromBottom = int(vm) + int(fraction * float(dataHeight));
            if (abs(fromBottom - guideFromBottom) <= 0) {
                guideColor = float3(0.35 * 0.6);
            }
        }
    } else {
        // Nits guides (logarithmic)
        float nitValues[5] = {0, 100, 500, 1000, 2000};
        for (int i = 0; i < 5; i++) {
            float fraction = nitsFraction(nitValues[i]);
            int guideFromBottom = int(vm) + int(fraction * float(dataHeight));
            if (abs(fromBottom - guideFromBottom) <= 0) {
                guideColor = float3(0.35 * 0.5);
            }
        }
        // SDR reference line (203 nits) — orange
        float sdrFraction = nitsFraction(sdrWhiteNits);
        int sdrFromBottom = int(vm) + int(sdrFraction * float(dataHeight));
        if (abs(fromBottom - sdrFromBottom) <= 0) {
            guideColor = float3(0.9, 0.65, 0.2) * 0.7;
        }
    }

    int level = (fromBottom - int(vm)) * int(params.levels - 1) / dataHeight;
    level = clamp(level, 0, int(params.levels) - 1);

    uint idx = dataX * params.levels + uint(level);
    uint count = bins[idx];

    if (count == 0) {
        output.write(half4(half3(guideColor), 1.0h), gid);
        return;
    }

    float logMax = log2(1.0 + float(maxCount));
    float gain = 2.5;
    float intensity = min(log2(1.0 + float(count)) / logMax * gain, 1.0);

    float invCount = 1.0 / float(count);
    float avgR = float(bins[binCount + idx]) * invCount / 255.0;
    float avgG = float(bins[2 * binCount + idx]) * invCount / 255.0;
    float avgB = float(bins[3 * binCount + idx]) * invCount / 255.0;

    // Saturation-aware coloring (matches CPU ScopeRenderService)
    float gray = (avgR + avgG + avgB) / 3.0;
    float maxDev = max(abs(avgR - gray), max(abs(avgG - gray), abs(avgB - gray)));
    float saturation = min(maxDev / max(gray, 0.01), 1.0);

    float satBoost = 2.5;
    float3 boosted;
    boosted.r = max(gray + (avgR - gray) * satBoost, 0.0);
    boosted.g = max(gray + (avgG - gray) * satBoost, 0.0);
    boosted.b = max(gray + (avgB - gray) * satBoost, 0.0);
    float maxC = max(max(boosted.r, boosted.g), max(boosted.b, 0.01));
    boosted /= maxC;

    float colorMix = min(saturation * 3.0, 1.0);
    float3 finalColor;
    finalColor.r = boosted.r * colorMix + (1.0 - colorMix);
    finalColor.g = boosted.g * colorMix + (1.0 - colorMix);
    finalColor.b = boosted.b * colorMix + (1.0 - colorMix);

    // In nits mode, tint HDR region orange
    if (params.scaleMode == 1) {
        float sdrFraction = nitsFraction(sdrWhiteNits);
        int sdrLevel = int(float(params.levels - 1) * sdrFraction);
        if (level > sdrLevel) {
            float hdrBlend = 0.4;
            finalColor.r = finalColor.r * (1 - hdrBlend) + 1.0 * hdrBlend;
            finalColor.g = finalColor.g * (1 - hdrBlend) + 0.7 * hdrBlend;
            finalColor.b = finalColor.b * (1 - hdrBlend) + 0.2 * hdrBlend;
        }
    }

    float3 result = guideColor + finalColor * intensity;
    result = min(result, float3(1.0));
    output.write(half4(half3(result), 1.0h), gid);
}

// ============================================================
// Parade Accumulate
// ============================================================

kernel void paradeAccumulate(
    texture2d<half, access::sample> source [[texture(0)]],
    texture1d<float, access::sample> toneLUT [[texture(1)]],
    device atomic_uint *bins [[buffer(0)]],
    constant ScopeEditParams &editParams [[buffer(1)]],
    constant ScopeParams &scopeParams [[buffer(2)]],
    constant MaskParams *masks [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint sW = scopeParams.channelWidth;
    uint sH = scopeParams.sampleHeight;
    if (gid.x >= sW || gid.y >= sH) return;

    // Remap UV from sample grid to crop region within source texture
    float2 uv = (float2(gid) + 0.5) / float2(sW, sH);
    uv = float2(scopeParams.cropLeft, scopeParams.cropTop)
       + uv * float2(scopeParams.cropRight - scopeParams.cropLeft,
                      scopeParams.cropBottom - scopeParams.cropTop);

    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    half4 color = source.sample(bilinear, uv);
    float3 rgb = float3(color.rgb);
    rgb = applyEdits(rgb, uv, editParams, toneLUT, masks);

    // Convert linear → sRGB before binning (matches CPU scope path)
    float r = linearToSRGB(saturate(rgb.r));
    float g = linearToSRGB(saturate(rgb.g));
    float b = linearToSRGB(saturate(rgb.b));
    float luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;

    int levels = int(scopeParams.levels);
    uint channelBinCount = scopeParams.channelWidth * scopeParams.levels;
    int x = int(gid.x);

    int rLevel, gLevel, bLevel, yLevel;
    if (scopeParams.scaleMode == 1) {
        // Nits mode: use raw linear — NO saturate() clamping.
        // linearToFraction() maps to [0, 1] via logarithmic nits scale with 10000-nit cap.
        float3 linear = max(rgb, float3(0));
        float levelsF = float(levels - 1);
        rLevel = clamp(int(linearToFraction(linear.r) * levelsF), 0, levels - 1);
        gLevel = clamp(int(linearToFraction(linear.g) * levelsF), 0, levels - 1);
        bLevel = clamp(int(linearToFraction(linear.b) * levelsF), 0, levels - 1);
        float lumaLinear = dot(linear, float3(0.2126, 0.7152, 0.0722));
        yLevel = clamp(int(linearToFraction(lumaLinear) * levelsF), 0, levels - 1);
    } else {
        float levelsF = float(levels - 1);
        rLevel = clamp(int(r * levelsF), 0, levels - 1);
        gLevel = clamp(int(g * levelsF), 0, levels - 1);
        bLevel = clamp(int(b * levelsF), 0, levels - 1);
        yLevel = clamp(int(luma * levelsF), 0, levels - 1);
    }

    atomic_fetch_add_explicit(&bins[0 * channelBinCount + uint(x * levels + rLevel)], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[1 * channelBinCount + uint(x * levels + gLevel)], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[2 * channelBinCount + uint(x * levels + bLevel)], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[3 * channelBinCount + uint(x * levels + yLevel)], 1, memory_order_relaxed);
}

// ============================================================
// Parade Render
// ============================================================

kernel void paradeRender(
    texture2d<half, access::write> output [[texture(0)]],
    device uint *bins [[buffer(0)]],
    constant ScopeParams &params [[buffer(1)]],
    constant uint &maxCount [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint outW = params.outputWidth;
    uint outH = params.outputHeight;
    if (gid.x >= outW || gid.y >= outH) return;

    // Label margin area
    if (gid.x < params.labelMargin) {
        output.write(half4(0, 0, 0, 1), gid);
        return;
    }

    uint dataX = gid.x - params.labelMargin;
    uint channelBinCount = params.channelWidth * params.levels;

    // Determine which channel this pixel belongs to
    int channel = -1;
    int localX = -1;
    for (int ch = 0; ch < 4; ch++) {
        uint chStart = uint(ch) * (params.channelWidth + params.channelGap);
        uint chEnd = chStart + params.channelWidth;
        if (dataX >= chStart && dataX < chEnd) {
            channel = ch;
            localX = int(dataX - chStart);
            break;
        }
    }

    // Gap / overflow — black
    if (channel < 0) {
        output.write(half4(0, 0, 0, 1), gid);
        return;
    }

    uint vm = params.verticalMargin;
    int dataHeight = int(outH) - int(vm * 2);
    int fromBottom = int(outH) - 1 - int(gid.y);

    if (fromBottom < int(vm) || fromBottom > int(vm) + dataHeight) {
        output.write(half4(0, 0, 0, 1), gid);
        return;
    }

    // Guide lines (same as waveform)
    float3 guideColor = float3(0);
    if (params.scaleMode == 0) {
        for (int i = 0; i <= 4; i++) {
            float fraction = float(i) * 0.25;
            int guideFromBottom = int(vm) + int(fraction * float(dataHeight));
            if (abs(fromBottom - guideFromBottom) <= 0) {
                guideColor = float3(0.35 * 0.6);
            }
        }
    } else {
        float nitValues[5] = {0, 100, 500, 1000, 2000};
        for (int i = 0; i < 5; i++) {
            float fraction = nitsFraction(nitValues[i]);
            int guideFromBottom = int(vm) + int(fraction * float(dataHeight));
            if (abs(fromBottom - guideFromBottom) <= 0) {
                guideColor = float3(0.35 * 0.5);
            }
        }
        float sdrFraction = nitsFraction(sdrWhiteNits);
        int sdrFromBottom = int(vm) + int(sdrFraction * float(dataHeight));
        if (abs(fromBottom - sdrFromBottom) <= 0) {
            guideColor = float3(0.9, 0.65, 0.2) * 0.7;
        }
    }

    int level = (fromBottom - int(vm)) * int(params.levels - 1) / dataHeight;
    level = clamp(level, 0, int(params.levels) - 1);

    uint idx = uint(channel) * channelBinCount + uint(localX) * params.levels + uint(level);
    uint count = bins[idx];

    if (count == 0) {
        output.write(half4(half3(guideColor), 1.0h), gid);
        return;
    }

    // Channel colors: R, G, B, Luma
    float3 channelColors[4] = {
        float3(1.0, 0.2, 0.2),
        float3(0.2, 1.0, 0.2),
        float3(0.3, 0.4, 1.0),
        float3(0.85, 0.85, 0.85),
    };

    // Logarithmic intensity — handles extreme dynamic range from saturated images
    // where one channel concentrates all counts in a few bins.
    float logMax = log2(1.0 + float(maxCount));
    float gain = 2.5;
    float intensity = min(log2(1.0 + float(count)) / logMax * gain, 1.0);
    float3 color = channelColors[channel] * intensity;

    float3 result = guideColor + color;
    result = min(result, float3(1.0));
    output.write(half4(half3(result), 1.0h), gid);
}

// ============================================================
// Vectorscope Accumulate
// ============================================================

kernel void vectorscopeAccumulate(
    texture2d<half, access::sample> source [[texture(0)]],
    texture1d<float, access::sample> toneLUT [[texture(1)]],
    device atomic_uint *bins [[buffer(0)]],
    constant ScopeEditParams &editParams [[buffer(1)]],
    constant ScopeParams &scopeParams [[buffer(2)]],
    constant MaskParams *masks [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= scopeParams.sampleWidth || gid.y >= scopeParams.sampleHeight) return;

    // Remap UV from sample grid to crop region within source texture
    float2 uv = (float2(gid) + 0.5) / float2(scopeParams.sampleWidth, scopeParams.sampleHeight);
    uv = float2(scopeParams.cropLeft, scopeParams.cropTop)
       + uv * float2(scopeParams.cropRight - scopeParams.cropLeft,
                      scopeParams.cropBottom - scopeParams.cropTop);

    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    half4 color = source.sample(bilinear, uv);
    float3 rgb = float3(color.rgb);
    rgb = applyEdits(rgb, uv, editParams, toneLUT, masks);

    // Convert linear → sRGB before CbCr computation (matches CPU scope path)
    float r = linearToSRGB(saturate(rgb.r));
    float g = linearToSRGB(saturate(rgb.g));
    float b = linearToSRGB(saturate(rgb.b));

    float cb = -0.1146 * r - 0.3854 * g + 0.5 * b;
    float cr =  0.5 * r - 0.4542 * g - 0.0458 * b;

    float outWf = float(scopeParams.outputWidth);
    float outHf = float(scopeParams.outputHeight);
    float centerX = outWf / 2.0;
    float centerY = outHf / 2.0;
    float margin = 8.0;
    float radius = min(centerX, centerY) - margin;

    int outX = int(centerX + cb * radius * 2);
    int outY = int(centerY + cr * radius * 2);

    if (outX < 0 || outX >= int(scopeParams.outputWidth) ||
        outY < 0 || outY >= int(scopeParams.outputHeight)) return;

    uint pixelCount = scopeParams.outputWidth * scopeParams.outputHeight;
    uint idx = uint(outY) * scopeParams.outputWidth + uint(outX);

    atomic_fetch_add_explicit(&bins[idx], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[pixelCount + idx], uint(r * 255.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[2 * pixelCount + idx], uint(g * 255.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[3 * pixelCount + idx], uint(b * 255.0), memory_order_relaxed);
}

// ============================================================
// Vectorscope Render
// ============================================================

kernel void vectorscopeRender(
    texture2d<half, access::write> output [[texture(0)]],
    device uint *bins [[buffer(0)]],
    constant ScopeParams &params [[buffer(1)]],
    constant uint &maxCount [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint outW = params.outputWidth;
    uint outH = params.outputHeight;
    if (gid.x >= outW || gid.y >= outH) return;

    uint pixelCount = outW * outH;
    float centerX = float(outW) / 2.0;
    float centerY = float(outH) / 2.0;
    float margin = 8.0;
    float radius = min(centerX, centerY) - margin;

    // Background + guides
    float3 bg = float3(0);

    // Circle outline
    float dist = length(float2(gid) - float2(centerX, centerY));
    if (abs(dist - radius) < 1.0) {
        bg = float3(0.18);
    }

    // Cross hairs
    if (abs(float(gid.x) - centerX) < 0.6 &&
        float(gid.y) >= margin && float(gid.y) < float(outH) - margin) {
        bg = float3(0.18);
    }
    if (abs(float(gid.y) - centerY) < 0.6 &&
        float(gid.x) >= margin && float(gid.x) < float(outW) - margin) {
        bg = float3(0.18);
    }

    // Skin tone line — negate Y (Cr) because data is Y-flipped in bin lookup
    float skinAngle = 2.146;
    float2 skinDir = float2(cos(skinAngle), -sin(skinAngle));
    float2 fromCenter = float2(gid) - float2(centerX, centerY);
    float skinProj = dot(fromCenter, skinDir);
    float skinDist = length(fromCenter - skinDir * skinProj);
    if (skinProj >= 0 && skinProj <= radius && skinDist < 1.5) {
        bg = float3(0.50, 0.42, 0.34);
    }

    // Color target boxes (BT.709 75%) — Cr (Y) negated to match flipped bin lookup
    float2 targets[6] = {
        float2(-0.0860, -0.3750),   // Red
        float2( 0.2891, -0.3407),   // Magenta
        float2( 0.3750,  0.0344),   // Blue
        float2( 0.0860,  0.3750),   // Cyan
        float2(-0.2891,  0.3407),   // Green
        float2(-0.3750, -0.0344),   // Yellow
    };
    float3 targetColors[6] = {
        float3(0.85, 0.20, 0.20),
        float3(0.85, 0.20, 0.85),
        float3(0.20, 0.20, 0.85),
        float3(0.20, 0.85, 0.85),
        float3(0.20, 0.85, 0.20),
        float3(0.85, 0.85, 0.20),
    };
    float boxSize = 18.0;
    for (int i = 0; i < 6; i++) {
        float tx = centerX + targets[i].x * radius * 2;
        float ty = centerY + targets[i].y * radius * 2;
        float2 tDist = abs(float2(gid) - float2(tx, ty));
        if (tDist.x < boxSize/2 + 1.25 && tDist.y < boxSize/2 + 1.25 &&
            (tDist.x > boxSize/2 - 1.25 || tDist.y > boxSize/2 - 1.25)) {
            bg = targetColors[i];
        }
    }

    // Flip Y for bin lookup (scope data has Y=0 at top, we rendered CbCr with Y increasing downward)
    uint srcY = outH - 1 - gid.y;
    uint idx = srcY * outW + gid.x;
    uint count = bins[idx];

    if (count == 0) {
        output.write(half4(half3(bg), 1.0h), gid);
        return;
    }

    float logMax = log2(1.0 + float(maxCount));
    float gain = 5.0;
    float intensity = max(min(log2(1.0 + float(count)) / logMax * gain, 1.0), 0.15);

    float invCount = 1.0 / float(count);
    float avgR = float(bins[pixelCount + idx]) * invCount / 255.0;
    float avgG = float(bins[2 * pixelCount + idx]) * invCount / 255.0;
    float avgB = float(bins[3 * pixelCount + idx]) * invCount / 255.0;

    // Saturation boost (matches CPU)
    float gray = (avgR + avgG + avgB) / 3.0;
    float satBoost = 2.0;
    avgR = max(gray + (avgR - gray) * satBoost, 0.05);
    avgG = max(gray + (avgG - gray) * satBoost, 0.05);
    avgB = max(gray + (avgB - gray) * satBoost, 0.05);
    float maxC = max(max(avgR, avgG), max(avgB, 0.01));
    avgR /= maxC; avgG /= maxC; avgB /= maxC;

    float3 dataColor = float3(avgR, avgG, avgB) * intensity;
    float3 result = bg + dataColor;
    result = min(result, float3(1.0));
    output.write(half4(half3(result), 1.0h), gid);
}

// ============================================================
// Chromaticity — Color Space Matrices (column-major for Metal)
// ============================================================

// sRGB linear -> XYZ (D65)
constant float3x3 sRGBtoXYZ = float3x3(
    float3(0.4124564, 0.2126729, 0.0193339),   // column 0 (R)
    float3(0.3575761, 0.7151522, 0.1191920),   // column 1 (G)
    float3(0.1804375, 0.0721750, 0.9503041)    // column 2 (B)
);

// Display P3 linear -> XYZ (D65)
constant float3x3 p3toXYZ = float3x3(
    float3(0.4865709, 0.2289746, 0.0000000),
    float3(0.2656677, 0.6917385, 0.0451134),
    float3(0.1982173, 0.0792869, 1.0439444)
);

// Rec.2020 linear -> XYZ (D65)
constant float3x3 rec2020toXYZ = float3x3(
    float3(0.6369580, 0.2627002, 0.0000000),
    float3(0.1446169, 0.6779981, 0.0280727),
    float3(0.1688810, 0.0593017, 1.0609851)
);

// sRGB -> Display P3 (for gamut clipping)
constant float3x3 sRGBtoP3 = float3x3(
    float3( 0.8225929,  0.0331995,  0.0170854),
    float3( 0.1775339,  0.9667835,  0.0723957),
    float3(-0.0000000,  0.0000000,  0.9103014)
);

// sRGB -> Rec.2020 (for gamut clipping)
constant float3x3 sRGBtoRec2020 = float3x3(
    float3( 0.6275037,  0.0691084,  0.0163940),
    float3( 0.3292755,  0.9195192,  0.0880112),
    float3( 0.0433027,  0.0113596,  0.8953803)
);

// Adobe RGB (1998) linear -> XYZ (D65)
constant float3x3 adobeRGBtoXYZ = float3x3(
    float3(0.5767309, 0.2973769, 0.0270343),
    float3(0.1855540, 0.6273491, 0.0706872),
    float3(0.1881852, 0.0752741, 0.9911085)
);

// sRGB -> Adobe RGB (for gamut clipping)
constant float3x3 sRGBtoAdobeRGB = float3x3(
    float3( 0.7151522,  0.0000000,  0.0000000),
    float3( 0.2848478,  0.9998940,  0.0411493),
    float3( 0.0000000,  0.0000000,  0.9587507)
);

// XYZ -> sRGB (for background color)
constant float3x3 xyzToSRGB = float3x3(
    float3( 3.2404548, -0.9692664,  0.0556434),
    float3(-1.5371389,  1.8760109, -0.2040259),
    float3(-0.4985315,  0.0415561,  1.0572252)
);

// Chromaticity diagram viewport
constant float xyMin = -0.05;
constant float xyRange = 0.90;

// ============================================================
// Spectral Locus Data (CIE 1931 2° observer, 5nm, 380–780nm)
// ============================================================

constant float2 spectralLocus[81] = {
    float2(0.1741, 0.0050), float2(0.1740, 0.0050), float2(0.1738, 0.0049),
    float2(0.1736, 0.0049), float2(0.1733, 0.0048), float2(0.1726, 0.0048),
    float2(0.1714, 0.0051), float2(0.1689, 0.0069), float2(0.1644, 0.0109),
    float2(0.1566, 0.0177), float2(0.1440, 0.0297), float2(0.1241, 0.0578),
    float2(0.0913, 0.1327), float2(0.0687, 0.2007), float2(0.0454, 0.2950),
    float2(0.0235, 0.4127), float2(0.0082, 0.5384), float2(0.0039, 0.6548),
    float2(0.0139, 0.7502), float2(0.0389, 0.8120), float2(0.0743, 0.8338),
    float2(0.1142, 0.8262), float2(0.1547, 0.8059), float2(0.1929, 0.7816),
    float2(0.2296, 0.7543), float2(0.2658, 0.7243), float2(0.3016, 0.6923),
    float2(0.3373, 0.6589), float2(0.3731, 0.6245), float2(0.4087, 0.5896),
    float2(0.4441, 0.5547), float2(0.4788, 0.5202), float2(0.5125, 0.4866),
    float2(0.5448, 0.4544), float2(0.5752, 0.4242), float2(0.6029, 0.3965),
    float2(0.6270, 0.3725), float2(0.6482, 0.3514), float2(0.6658, 0.3340),
    float2(0.6801, 0.3197), float2(0.6915, 0.3083), float2(0.7006, 0.2993),
    float2(0.7079, 0.2920), float2(0.7140, 0.2859), float2(0.7190, 0.2809),
    float2(0.7230, 0.2770), float2(0.7260, 0.2740), float2(0.7283, 0.2717),
    float2(0.7300, 0.2700), float2(0.7311, 0.2689), float2(0.7320, 0.2680),
    float2(0.7327, 0.2673), float2(0.7334, 0.2666), float2(0.7340, 0.2660),
    float2(0.7344, 0.2656), float2(0.7346, 0.2654), float2(0.7347, 0.2653),
    float2(0.7347, 0.2653), float2(0.7347, 0.2653), float2(0.7347, 0.2653),
    float2(0.7347, 0.2653), float2(0.7347, 0.2653), float2(0.7347, 0.2653),
    float2(0.7347, 0.2653), float2(0.7347, 0.2653), float2(0.7347, 0.2653),
    float2(0.7347, 0.2653), float2(0.7347, 0.2653), float2(0.7347, 0.2653),
    float2(0.7347, 0.2653), float2(0.7347, 0.2653), float2(0.7347, 0.2653),
    float2(0.7347, 0.2653), float2(0.7347, 0.2653), float2(0.7347, 0.2653),
    float2(0.7347, 0.2653), float2(0.7347, 0.2653), float2(0.7347, 0.2653),
    float2(0.7347, 0.2653), float2(0.7347, 0.2653), float2(0.7347, 0.2653),
};
constant uint spectralLocusCount = 81;

// ============================================================
// Chromaticity Helpers
// ============================================================

inline float distToSegment(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return length(p - (a + t * ab));
}

// Point-in-polygon test for spectral locus
inline bool isInsideLocus(float2 pt) {
    bool inside = false;
    uint j = spectralLocusCount - 1;
    for (uint i = 0; i < spectralLocusCount; i++) {
        float xi = spectralLocus[i].x, yi = spectralLocus[i].y;
        float xj = spectralLocus[j].x, yj = spectralLocus[j].y;
        if (((yi > pt.y) != (yj > pt.y)) &&
            (pt.x < (xj - xi) * (pt.y - yi) / (yj - yi) + xi)) {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

// Point-in-triangle test (barycentric method)
inline bool isInsideTriangle(float2 p, float2 a, float2 b, float2 c) {
    float2 v0 = c - a, v1 = b - a, v2 = p - a;
    float d00 = dot(v0, v0);
    float d01 = dot(v0, v1);
    float d02 = dot(v0, v2);
    float d11 = dot(v1, v1);
    float d12 = dot(v1, v2);
    float inv = 1.0 / (d00 * d11 - d01 * d01);
    float u = (d11 * d02 - d01 * d12) * inv;
    float v = (d00 * d12 - d01 * d02) * inv;
    return (u >= 0.0) && (v >= 0.0) && (u + v <= 1.0);
}

// ============================================================
// Chromaticity Accumulate
// ============================================================

kernel void chromaticityAccumulate(
    texture2d<half, access::sample> source [[texture(0)]],
    texture1d<float, access::sample> toneLUT [[texture(1)]],
    device atomic_uint *bins [[buffer(0)]],
    constant ScopeEditParams &editParams [[buffer(1)]],
    constant ScopeParams &scopeParams [[buffer(2)]],
    constant MaskParams *masks [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= scopeParams.sampleWidth || gid.y >= scopeParams.sampleHeight) return;

    // Remap UV from sample grid to crop region within source texture
    float2 uv = (float2(gid) + 0.5) / float2(scopeParams.sampleWidth, scopeParams.sampleHeight);
    uv = float2(scopeParams.cropLeft, scopeParams.cropTop)
       + uv * float2(scopeParams.cropRight - scopeParams.cropLeft,
                      scopeParams.cropBottom - scopeParams.cropTop);

    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    half4 color = source.sample(bilinear, uv);
    float3 rgb = float3(color.rgb);
    rgb = applyEdits(rgb, uv, editParams, toneLUT, masks);

    // Work in linear space for chromaticity — do NOT apply linearToSRGB
    float3 linearRGB = rgb;
    float3x3 xyzMat = sRGBtoXYZ;

    if (scopeParams.clipMode == 1) {
        if (scopeParams.targetGamut == 0) {
            // sRGB: just clamp
            linearRGB = clamp(linearRGB, 0.0, 1.0);
        } else if (scopeParams.targetGamut == 1) {
            // Display P3: convert, clamp, use P3 XYZ matrix
            linearRGB = clamp(sRGBtoP3 * linearRGB, 0.0, 1.0);
            xyzMat = p3toXYZ;
        } else if (scopeParams.targetGamut == 2) {
            // Rec.2020: convert, clamp, use Rec.2020 XYZ matrix
            linearRGB = clamp(sRGBtoRec2020 * linearRGB, 0.0, 1.0);
            xyzMat = rec2020toXYZ;
        } else {
            // Adobe RGB: convert, clamp, use Adobe RGB XYZ matrix
            linearRGB = clamp(sRGBtoAdobeRGB * linearRGB, 0.0, 1.0);
            xyzMat = adobeRGBtoXYZ;
        }
    }

    float3 xyz = xyzMat * linearRGB;
    if (xyz.x < 0.0 || xyz.y < 0.0 || xyz.z < 0.0) return;  // skip imaginary colors
    float sum = xyz.x + xyz.y + xyz.z;
    if (sum < 0.001) return;

    float cx = xyz.x / sum;
    float cy = xyz.y / sum;

    int outW = int(scopeParams.outputWidth);
    int outH = int(scopeParams.outputHeight);
    int outX = int((cx - xyMin) / xyRange * float(outW - 1));
    int outY = outH - 1 - int((cy - xyMin) / xyRange * float(outH - 1));

    if (outX < 0 || outX >= outW || outY < 0 || outY >= outH) return;

    uint pixelCount = scopeParams.outputWidth * scopeParams.outputHeight;
    uint idx = uint(outY) * scopeParams.outputWidth + uint(outX);

    // Color accumulation: use sRGB-clamped values for display
    float r = linearToSRGB(saturate(rgb.r));
    float g = linearToSRGB(saturate(rgb.g));
    float b = linearToSRGB(saturate(rgb.b));

    atomic_fetch_add_explicit(&bins[idx], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[pixelCount + idx], uint(r * 255.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[2 * pixelCount + idx], uint(g * 255.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[3 * pixelCount + idx], uint(b * 255.0), memory_order_relaxed);
}

// ============================================================
// Chromaticity Render
// ============================================================

kernel void chromaticityRender(
    texture2d<half, access::write> output [[texture(0)]],
    device uint *bins [[buffer(0)]],
    constant ScopeParams &params [[buffer(1)]],
    constant uint &maxCount [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint outW = params.outputWidth;
    uint outH = params.outputHeight;
    if (gid.x >= outW || gid.y >= outH) return;

    uint pixelCount = outW * outH;

    // Compute CIE xy for this pixel
    float cx = xyMin + (float(gid.x) + 0.5) / float(outW) * xyRange;
    float cy = xyMin + (float(outH - 1 - gid.y) + 0.5) / float(outH) * xyRange;
    float2 xyPos = float2(cx, cy);

    // Background: dim colorful CIE diagram inside spectral locus
    float3 bg = float3(0);
    if (isInsideLocus(xyPos) && cy > 0.001) {
        float Y = 0.5;
        float X = (cx / cy) * Y;
        float Z = ((1.0 - cx - cy) / cy) * Y;
        float3 srgb = xyzToSRGB * float3(X, Y, Z);
        srgb = max(srgb, 0.0);
        float maxC = max(max(srgb.r, srgb.g), max(srgb.b, 0.001));
        srgb /= maxC;
        bg = srgb * 0.12;
    }

    // Spectral locus outline
    float minLocusDist = 1e10;
    for (uint i = 0; i < spectralLocusCount; i++) {
        uint j = (i + 1) % spectralLocusCount;
        float d = distToSegment(xyPos, spectralLocus[i], spectralLocus[j]);
        minLocusDist = min(minLocusDist, d);
    }
    float locusPx = minLocusDist / xyRange * float(outW);
    if (locusPx < 1.5) {
        float blend = 1.0 - locusPx / 1.5;
        bg = max(bg, float3(0.25 * blend * 0.8));
    }

    // Gamut triangles
    // sRGB primaries
    float2 sRGBTri[3] = { float2(0.640, 0.330), float2(0.300, 0.600), float2(0.150, 0.060) };
    // Display P3 primaries
    float2 p3Tri[3] = { float2(0.680, 0.320), float2(0.265, 0.690), float2(0.150, 0.060) };
    // Rec.2020 primaries
    float2 r2020Tri[3] = { float2(0.708, 0.292), float2(0.170, 0.797), float2(0.131, 0.046) };
    // Adobe RGB primaries (shares R and B with sRGB, different G)
    float2 adobeTri[3] = { float2(0.640, 0.330), float2(0.210, 0.710), float2(0.150, 0.060) };

    struct GamutInfo {
        float2 verts[3];
        float3 color;
        uint gamutId;  // 0=sRGB, 1=P3, 2=Rec2020, 3=AdobeRGB
    };

    GamutInfo gamuts[4];
    gamuts[0] = { { r2020Tri[0], r2020Tri[1], r2020Tri[2] }, float3(0.3, 0.8, 0.9), 2 };
    gamuts[1] = { { p3Tri[0], p3Tri[1], p3Tri[2] }, float3(0.9, 0.6, 0.2), 1 };
    gamuts[2] = { { adobeTri[0], adobeTri[1], adobeTri[2] }, float3(0.6, 0.9, 0.4), 3 };
    gamuts[3] = { { sRGBTri[0], sRGBTri[1], sRGBTri[2] }, float3(0.8, 0.8, 0.8), 0 };

    // Display gamut indicator: fill and enhanced outline showing the display's gamut capability
    if (params.displayGamut != 0 && params.displayGamut != params.targetGamut) {
        float2 dispTri[3];
        if (params.displayGamut == 1) { dispTri[0] = p3Tri[0]; dispTri[1] = p3Tri[1]; dispTri[2] = p3Tri[2]; }
        else if (params.displayGamut == 2) { dispTri[0] = r2020Tri[0]; dispTri[1] = r2020Tri[1]; dispTri[2] = r2020Tri[2]; }
        else { dispTri[0] = adobeTri[0]; dispTri[1] = adobeTri[1]; dispTri[2] = adobeTri[2]; }

        if (isInsideTriangle(xyPos, dispTri[0], dispTri[1], dispTri[2])
            && !isInsideTriangle(xyPos, sRGBTri[0], sRGBTri[1], sRGBTri[2])) {
            bg = max(bg, float3(0.12, 0.08, 0.0));
        }
    }

    for (int g = 0; g < 4; g++) {
        bool isTarget = (gamuts[g].gamutId == params.targetGamut);
        bool isDisplay = (gamuts[g].gamutId == params.displayGamut) && !isTarget;
        float alpha = isTarget ? 0.7 : (isDisplay ? 0.55 : 0.3);
        float lineThick = isTarget ? 2.0 : (isDisplay ? 1.5 : 1.0);

        for (int e = 0; e < 3; e++) {
            float2 a = gamuts[g].verts[e];
            float2 b = gamuts[g].verts[(e + 1) % 3];
            float d = distToSegment(xyPos, a, b);
            float dPx = d / xyRange * float(outW);
            if (dPx < lineThick) {
                float blend = (1.0 - dPx / lineThick) * alpha;
                bg = max(bg, gamuts[g].color * blend);
            }
        }
    }

    // D65 white point crosshair
    float2 d65 = float2(0.3127, 0.3290);
    float d65DistX = abs(cx - d65.x);
    float d65DistY = abs(cy - d65.y);
    float d65PxX = d65DistX / xyRange * float(outW);
    float d65PxY = d65DistY / xyRange * float(outH);
    float armLen = 5.0;
    if ((d65PxX < 0.6 && d65PxY < armLen) || (d65PxY < 0.6 && d65PxX < armLen)) {
        bg = max(bg, float3(0.56));
    }

    // Bin lookup (Y is NOT flipped for chromaticity — we stored outY directly)
    uint idx = gid.y * outW + gid.x;
    uint count = bins[idx];

    if (count == 0) {
        output.write(half4(half3(bg), 1.0h), gid);
        return;
    }

    float logMax = log2(1.0 + float(maxCount));
    float gain = 5.0;
    float intensity = max(min(log2(1.0 + float(count)) / logMax * gain, 1.0), 0.15);

    float invCount = 1.0 / float(count);
    float avgR = float(bins[pixelCount + idx]) * invCount / 255.0;
    float avgG = float(bins[2 * pixelCount + idx]) * invCount / 255.0;
    float avgB = float(bins[3 * pixelCount + idx]) * invCount / 255.0;

    // Saturation boost (matches CPU)
    float gray = (avgR + avgG + avgB) / 3.0;
    float satBoost = 2.0;
    avgR = max(gray + (avgR - gray) * satBoost, 0.05);
    avgG = max(gray + (avgG - gray) * satBoost, 0.05);
    avgB = max(gray + (avgB - gray) * satBoost, 0.05);
    float maxC = max(max(avgR, avgG), max(avgB, 0.01));
    avgR /= maxC; avgG /= maxC; avgB /= maxC;

    float3 dataColor = float3(avgR, avgG, avgB) * intensity;
    float3 result = bg + dataColor;
    result = min(result, float3(1.0));
    output.write(half4(half3(result), 1.0h), gid);
}

// ============================================================
// Find Max Count (parallel reduction)
// ============================================================

kernel void scopeFindMaxCount(
    device uint *counts [[buffer(0)]],
    device atomic_uint *result [[buffer(1)]],
    constant uint &totalCount [[buffer(2)]],
    uint gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]])
{
    threadgroup uint localMax[256];

    uint val = (gid < totalCount) ? counts[gid] : 0;
    localMax[tid] = val;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (tid < stride) {
            localMax[tid] = max(localMax[tid], localMax[tid + stride]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        uint current = atomic_load_explicit(result, memory_order_relaxed);
        uint newVal = localMax[0];
        while (newVal > current) {
            if (atomic_compare_exchange_weak_explicit(result, &current, newVal,
                                                      memory_order_relaxed, memory_order_relaxed)) {
                break;
            }
        }
    }
}

// ============================================================
// Blit — full-screen quad to copy scope texture to drawable
// ============================================================

struct BlitVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlitVertexOut scopeBlitVertex(uint vid [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1, -1),
        float2( 1, -1),
        float2(-1,  1),
        float2( 1,  1),
    };
    BlitVertexOut out;
    out.position = float4(positions[vid], 0, 1);
    // Map clip space to UV: bottom-left → (0,1), top-right → (1,0)
    out.uv = float2(positions[vid].x + 1.0, 1.0 - positions[vid].y) * 0.5;
    return out;
}

fragment half4 scopeBlitFragment(
    BlitVertexOut in [[stage_in]],
    texture2d<half, access::sample> scopeTexture [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return scopeTexture.sample(s, in.uv);
}
