#include <metal_stdlib>
using namespace metal;

// ============================================================
// EditParams — must match Swift EditParams and EditAdjustments.metal exactly
// ============================================================

struct ScopeEditParams {
    float exposure;
    float vibrance;
    float saturation;
    float pad0;

    float3x3 whiteBalanceMatrix;

    uint activeFlags;
    uint maskCount;

    float2 scale;
    float2 sourceSize;
    float2 drawableSize;

    float lutDomainMin;
    float lutDomainMax;
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
};

// ============================================================
// Nits scale conversion (matches WaveformScale in Swift)
// ============================================================

constant float sdrWhiteNits = 203.0;
constant float maxNits = 10000.0;
constant float logK = 0.1;
constant float logDenom = 3.0004; // log10(1 + 10000 * 0.1)

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
    constant ScopeEditParams &params,
    texture1d<float, access::sample> toneLUT)
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
        // Highlight desaturation
        float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float desat = smoothstep(0.55, 1.3, lum) * 0.7;
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
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= scopeParams.sampleWidth || gid.y >= scopeParams.sampleHeight) return;

    float2 uv = (float2(gid) + 0.5) / float2(scopeParams.sampleWidth, scopeParams.sampleHeight);
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    half4 color = source.sample(bilinear, uv);
    float3 rgb = float3(color.rgb);
    rgb = applyEdits(rgb, editParams, toneLUT);

    // Convert linear → sRGB before binning (matches CPU scope path)
    float r = linearToSRGB(saturate(rgb.r));
    float g = linearToSRGB(saturate(rgb.g));
    float b = linearToSRGB(saturate(rgb.b));
    float luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;

    int levels = int(scopeParams.levels);
    int level;
    if (scopeParams.scaleMode == 1) {
        // Nits mode uses linear light values for logarithmic mapping
        float lumaLinear = dot(saturate(rgb), float3(0.2126, 0.7152, 0.0722));
        level = clamp(int(linearToFraction(lumaLinear) * float(levels - 1)), 0, levels - 1);
    } else {
        level = clamp(int(luma * float(levels - 1)), 0, levels - 1);
    }

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
        float nitValues[5] = {0, 100, 1000, 4000, 10000};
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
    uint2 gid [[thread_position_in_grid]])
{
    uint sW = scopeParams.channelWidth;
    uint sH = scopeParams.sampleHeight;
    if (gid.x >= sW || gid.y >= sH) return;

    float2 uv = (float2(gid) + 0.5) / float2(sW, sH);
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    half4 color = source.sample(bilinear, uv);
    float3 rgb = float3(color.rgb);
    rgb = applyEdits(rgb, editParams, toneLUT);

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
        // Nits mode: use linear light for logarithmic mapping
        float3 linear = saturate(rgb);
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
        float nitValues[5] = {0, 100, 1000, 4000, 10000};
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
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= scopeParams.sampleWidth || gid.y >= scopeParams.sampleHeight) return;

    float2 uv = (float2(gid) + 0.5) / float2(scopeParams.sampleWidth, scopeParams.sampleHeight);
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    half4 color = source.sample(bilinear, uv);
    float3 rgb = float3(color.rgb);
    rgb = applyEdits(rgb, editParams, toneLUT);

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
    if (skinProj >= 0 && skinProj <= radius && skinDist < 1.0) {
        bg = float3(0.36, 0.30, 0.24);
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
        float3(0.7, 0.15, 0.15),
        float3(0.7, 0.15, 0.7),
        float3(0.15, 0.15, 0.7),
        float3(0.15, 0.7, 0.7),
        float3(0.15, 0.7, 0.15),
        float3(0.7, 0.7, 0.15),
    };
    float boxSize = 18.0;
    for (int i = 0; i < 6; i++) {
        float tx = centerX + targets[i].x * radius * 2;
        float ty = centerY + targets[i].y * radius * 2;
        float2 tDist = abs(float2(gid) - float2(tx, ty));
        if (tDist.x < boxSize/2 + 1.25 && tDist.y < boxSize/2 + 1.25 &&
            (tDist.x > boxSize/2 - 1.25 || tDist.y > boxSize/2 - 1.25)) {
            bg = targetColors[i] * 0.85;
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
    float gain = 3.0;
    float intensity = min(log2(1.0 + float(count)) / logMax * gain, 1.0);

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
