#include <metal_stdlib>
using namespace metal;

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

struct HSLChannelParams {
    float saturation;       // -1..1
    float luminance;        // -1..1
    float hueShift;         // degrees (-30..30)
    float _pad;
};

struct HSLParams {
    HSLChannelParams channels[7]; // 0=Red, 1=Yellow, 2=Green, 3=Cyan, 4=Blue, 5=Magenta, 6=SkinTone
    uint activeFlags;             // bit0 = any HSL active
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

struct EditParams {
    float exposure;          // EV (legacy field, baked into LUT when LUT is active)
    float vibrance;          // -1..1
    float saturation;        // 0..2 (1=identity)
    uint gamutClipMode;      // 0=off, 1=sRGB, 2=P3, 3=Rec2020

    float3x3 whiteBalanceMatrix; // Bradford chromatic adaptation (identity if no WB)

    uint activeFlags;        // bitmask: bit0=toneLUT, bit1=vibrance,
                             // bit2=saturation, bit3=whiteBalance, bit4=hdrMode
    uint maskCount;          // number of active masks (0-8)

    float2 scale;            // source→drawable scale (stretch-to-fill)
    float2 sourceSize;       // source texture dimensions
    float2 drawableSize;     // output drawable dimensions

    float2 viewportOrigin;   // top-left of visible region in normalized [0,1] source coords
    float2 viewportSize;     // fraction of source visible per axis (1,1 = full image)

    float lutDomainMin;      // -0.5 (extended range for color matrix overshoot)
    float lutDomainMax;      // 4.0 (HDR headroom)
};

// ============================================================
// Gamut-clipping matrices (soft proof)
// ============================================================

// sRGB -> Display P3 (column-major)
constant float3x3 sRGBtoP3_edit = float3x3(
    float3( 0.8225929,  0.0331995,  0.0170854),
    float3( 0.1775339,  0.9667835,  0.0723957),
    float3( 0.0000000,  0.0000000,  0.9103014)
);
// Display P3 -> sRGB (column-major)
constant float3x3 P3toSRGB_edit = float3x3(
    float3( 1.2247452, -0.0420579, -0.0196423),
    float3(-0.2249043,  1.0420810, -0.0786548),
    float3( 0.0000000,  0.0000000,  1.0985373)
);
// sRGB -> Rec.2020 (column-major)
constant float3x3 sRGBtoRec2020_edit = float3x3(
    float3( 0.6275037,  0.0691084,  0.0163940),
    float3( 0.3292755,  0.9195192,  0.0880112),
    float3( 0.0433027,  0.0113596,  0.8953803)
);
// Rec.2020 -> sRGB (column-major)
constant float3x3 Rec2020toSRGB_edit = float3x3(
    float3( 1.6602270, -0.1245536, -0.0181550),
    float3(-0.5875478,  1.1329261, -0.1006030),
    float3(-0.0728383, -0.0083496,  1.1189982)
);
// sRGB -> Adobe RGB (column-major)
constant float3x3 sRGBtoAdobeRGB_edit = float3x3(
    float3( 0.7151522,  0.0000000,  0.0000000),
    float3( 0.2848478,  0.9998940,  0.0411493),
    float3( 0.0000000,  0.0000000,  0.9587507)
);
// Adobe RGB -> sRGB (column-major)
constant float3x3 AdobeRGBtoSRGB_edit = float3x3(
    float3( 1.3982403,  0.0000000,  0.0000000),
    float3(-0.3982659,  1.0001061, -0.0429013),
    float3( 0.0000000,  0.0000000,  1.0427550)
);

kernel void editAdjustments(
    texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    texture1d<float, access::sample> toneLUT [[texture(2)]],
    constant EditParams &params [[buffer(0)]],
    constant MaskParams *masks [[buffer(1)]],
    constant HSLParams &hslParams [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.drawableSize.x) || gid.y >= uint(params.drawableSize.y)) {
        return;
    }

    // Map drawable pixel through viewport to source UV
    float2 drawableNorm = float2(gid) / params.drawableSize;
    float2 uv = params.viewportOrigin + drawableNorm * params.viewportSize;

    // Letterbox: dark gray for pixels outside source bounds
    // 0.0197 linear ≈ sRGB 0.15, matching SwiftUI previewBackground
    if (uv.x < 0.0 || uv.x >= 1.0 || uv.y < 0.0 || uv.y >= 1.0) {
        destination.write(half4(0.0197, 0.0197, 0.0197, 1), gid);
        return;
    }

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

        float4 rSample = toneLUT.sample(lutSampler, ur);
        float4 gSample = toneLUT.sample(lutSampler, ug);
        float4 bSample = toneLUT.sample(lutSampler, ub);
        rgb.r = half(rSample.r);
        rgb.g = half(gSample.g);
        rgb.b = half(bSample.b);

        // Highlight desaturation: blend toward luminance as brightness increases.
        // Prevents per-channel LUT from oversaturating highlights — ACR rolls off
        // bright areas toward neutral white rather than boosting channel differences.
        // HDR mode: shift thresholds up so the SDR range retains full color.
        float3 rgbF = float3(rgb);
        float lum = dot(rgbF, float3(0.2126, 0.7152, 0.0722));
        bool isHDR = (params.activeFlags & (1u << 4)) != 0;
        float desatLow  = isHDR ? 1.5  : 0.85;
        float desatHigh = isHDR ? 4.0  : 1.6;
        float desatMax  = isHDR ? 0.5  : 0.40;
        float desat = smoothstep(desatLow, desatHigh, lum) * desatMax;
        rgb = half3(mix(rgbF, float3(lum), desat));
    }

    // 2.5. Per-color HSL adjustments (Hue / Saturation / Density)
    //
    // Processing order: Hue → Saturation → Density.
    // Hue shift changes the base color first, then sat/density modify its appearance.
    //   Hue shift:  rotate hue in HSL space (round-trip only when active)
    //   Saturation: mix toward/away from luminance in RGB space
    //   Density:    adjust luminance while preserving chrominance (Resolve Hue-vs-Lum style)
    if (hslParams.activeFlags & 1u) {
        float3 rgbF = float3(rgb);

        // HDR safety: normalize super-white pixels to 0-1, restore after
        float hdrPeak = max3(rgbF.r, rgbF.g, rgbF.b);
        float hdrScale = 1.0;
        if (hdrPeak > 1.0) {
            hdrScale = hdrPeak;
            rgbF /= hdrScale;
        }

        // Extract hue and saturation for weight computation
        float maxC = max3(rgbF.r, rgbF.g, rgbF.b);
        float minC = min3(rgbF.r, rgbF.g, rgbF.b);
        float chroma = maxC - minC;

        if (chroma > 0.001) {
            float sat = (maxC > 0.001) ? (chroma / maxC) : 0.0;

            // Hue in degrees [0, 360)
            float hue = 0.0;
            if (maxC == rgbF.r)      hue = fmod((rgbF.g - rgbF.b) / chroma + 6.0, 6.0) * 60.0;
            else if (maxC == rgbF.g) hue = ((rgbF.b - rgbF.r) / chroma + 2.0) * 60.0;
            else                     hue = ((rgbF.r - rgbF.g) / chroma + 4.0) * 60.0;

            // Channel centers (degrees) and Gaussian sigmas.
            // Gaussian weighting: smooth decay, no hard cutoff at any boundary.
            // Sigma ~22° for primaries (≈40° FWHM), ~11° for skin tone.
            float centers[7] = { 0.0, 60.0, 120.0, 180.0, 240.0, 300.0, 22.0 };
            float sigmas[7] = { 22.0, 22.0, 22.0, 22.0, 22.0, 22.0, 11.0 };

            float totalSatDelta = 0.0;
            float totalDensDelta = 0.0;
            float totalHueDelta = 0.0;

            for (int i = 0; i < 7; i++) {
                float dist = abs(hue - centers[i]);
                if (dist > 180.0) dist = 360.0 - dist;

                // Gaussian: smooth decay, effectively zero beyond ~3 sigma
                float weight = exp(-0.5 * (dist * dist) / (sigmas[i] * sigmas[i]));

                // Skin tone: gate on saturation (desaturated pixels are not skin)
                if (i == 6) {
                    weight *= smoothstep(0.05, 0.20, sat);
                }

                totalSatDelta += weight * hslParams.channels[i].saturation;
                totalDensDelta += weight * hslParams.channels[i].luminance;
                totalHueDelta += weight * hslParams.channels[i].hueShift;
            }

            // 1. Hue shift — rotate hue in HSL space (must come first so sat/dens
            //    operate on the final color, not the pre-shift color).
            if (abs(totalHueDelta) > 0.001) {
                float mx = max3(rgbF.r, rgbF.g, rgbF.b);
                float mn = min3(rgbF.r, rgbF.g, rgbF.b);
                float ch = mx - mn;
                float lum2 = (mx + mn) * 0.5;
                float sat2 = 0.0;
                if (ch > 0.001) {
                    sat2 = ch / (1.0 - abs(2.0 * lum2 - 1.0) + 0.001);
                    sat2 = clamp(sat2, 0.0, 1.0);
                }

                float hue2 = 0.0;
                if (ch > 0.001) {
                    if (mx == rgbF.r)      hue2 = fmod((rgbF.g - rgbF.b) / ch + 6.0, 6.0) * 60.0;
                    else if (mx == rgbF.g) hue2 = ((rgbF.b - rgbF.r) / ch + 2.0) * 60.0;
                    else                   hue2 = ((rgbF.r - rgbF.g) / ch + 4.0) * 60.0;
                }

                hue2 = fmod(hue2 + totalHueDelta + 360.0, 360.0);

                float C = (1.0 - abs(2.0 * lum2 - 1.0)) * sat2;
                float hP = hue2 / 60.0;
                float X = C * (1.0 - abs(fmod(hP, 2.0) - 1.0));
                float3 rgb1;
                if      (hP < 1.0) rgb1 = float3(C, X, 0);
                else if (hP < 2.0) rgb1 = float3(X, C, 0);
                else if (hP < 3.0) rgb1 = float3(0, C, X);
                else if (hP < 4.0) rgb1 = float3(0, X, C);
                else if (hP < 5.0) rgb1 = float3(X, 0, C);
                else               rgb1 = float3(C, 0, X);
                rgbF = rgb1 + float3(lum2 - C * 0.5);
            }

            // 2. Saturation — mix toward/away from luminance in RGB space.
            if (abs(totalSatDelta) > 0.001) {
                float lumR = dot(rgbF, float3(0.2126, 0.7152, 0.0722));
                rgbF = mix(float3(lumR), rgbF, 1.0 + totalSatDelta);
            }

            // 3. Density — adjust luminance while preserving chrominance.
            //    Positive slider = more dense = darker (photography convention).
            //    Negative slider = less dense = brighter.
            //    Uses pow() for both directions: multiplicative in nature,
            //    so the effect naturally tapers near the hue boundary (no hard edges).
            if (abs(totalDensDelta) > 0.001) {
                float Y = dot(rgbF, float3(0.2126, 0.7152, 0.0722));
                float3 colorChroma = rgbF - float3(Y);

                // Negate: positive slider → darker → lower luminance.
                // pow(2, ...) gives ~2x range: +1 → 0.5x, -1 → 2x.
                float gain = pow(2.0, -totalDensDelta);
                float Y_new = clamp(Y * gain, 0.0, 1.0);

                rgbF = float3(Y_new) + colorChroma;
            }

            // Restore HDR brightness and clamp
            rgbF = max(rgbF, 0.0) * hdrScale;
            rgb = half3(rgbF);
        }
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

    // 5. Local mask adjustments — analytical ellipse masks
    for (uint m = 0; m < params.maskCount && m < 8; m++) {
        constant MaskParams &mask = masks[m];

        // Compute ellipse mask weight analytically
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

        half3 adjusted = rgb;

        // Exposure: multiplicative EV shift
        if (mask.activeFlags & (1u << 0)) {
            adjusted *= half(exp2(mask.exposure));
        }
        // Contrast: ACR parametric sigmoid — gain peaks at midtones, falls at extremes
        if (mask.activeFlags & (1u << 1)) {
            for (int c = 0; c < 3; c++) {
                float x = float(adjusted[c]);
                float centered = x - 0.5;
                float falloff = min(4.0 * centered * centered, 1.0);
                float gain = 1.0 + mask.contrast * 0.7 * (1.0 - falloff);
                adjusted[c] = half(0.5 + centered * max(gain, 0.1));
            }
        }
        // Blacks: tapered shadow-region adjustment in sqrt-space
        if (mask.activeFlags & (1u << 5)) {
            for (int c = 0; c < 3; c++) {
                float x = float(adjusted[c]);
                float px = sqrt(max(0.0, x));
                float boundary = mask.blacks < 0 ? 0.50 : 0.35;
                float amplitude = mask.blacks < 0 ? 0.14 : 0.10;
                float shadowRegion = max(0.0, 1.0 - px / boundary);
                float delta = mask.blacks * amplitude * shadowRegion;
                float pxNew = max(0.0, px + delta);
                adjusted[c] = half(pxNew * pxNew);
            }
        }
        // Shadows: Gaussian-weighted lift in sqrt-space
        if (mask.activeFlags & (1u << 3)) {
            for (int c = 0; c < 3; c++) {
                float x = float(adjusted[c]);
                float px = sqrt(max(0.0, x));
                float ctr = 0.15;
                float w = 0.15;
                float d = (px - ctr) / w;
                float delta = mask.shadows * 0.08 * exp(-0.5 * d * d);
                float pxNew = max(0.0, px + delta);
                adjusted[c] = half(pxNew * pxNew);
            }
        }
        // Highlights: one-sided ramp for upper tones
        if (mask.activeFlags & (1u << 2)) {
            float knee = 0.15;
            for (int c = 0; c < 3; c++) {
                float x = float(adjusted[c]);
                if (x > knee) {
                    float t = min((x - knee) / 0.85, 1.0);
                    float wt = t * t * (3.0 - 2.0 * t) * (1.0 - t * t * 0.3);
                    adjusted[c] = half(x + mask.highlights * 0.30 * wt);
                }
            }
        }
        // Whites: upper tone range adjustment
        if (mask.activeFlags & (1u << 4)) {
            float knee = 0.45;
            for (int c = 0; c < 3; c++) {
                float x = float(adjusted[c]);
                if (x > knee) {
                    float t = (x - knee) / (1.0 - knee);
                    float tClamped = min(t, 2.0);
                    if (mask.whites > 0) {
                        float tSat = min(tClamped, 1.0);
                        float wt = tSat * tSat * (3.0 - 2.0 * tSat);
                        x += mask.whites * 1.2 * wt;
                    } else {
                        float pull = sqrt(tClamped) * 0.25;
                        x -= abs(mask.whites) * pull * (1.0 - knee);
                    }
                    adjusted[c] = half(x);
                }
            }
        }
        // Saturation
        if (mask.activeFlags & (1u << 6)) {
            half lum = dot(adjusted, half3(0.2126h, 0.7152h, 0.0722h));
            adjusted = mix(half3(lum), adjusted, half(mask.saturation));
        }
        // Vibrance: selective saturation boost
        if (mask.activeFlags & (1u << 7)) {
            half lum = dot(adjusted, half3(0.2126h, 0.7152h, 0.0722h));
            half maxC = max3(adjusted.r, adjusted.g, adjusted.b);
            half minC = min3(adjusted.r, adjusted.g, adjusted.b);
            half sat = (maxC > 0.001h) ? ((maxC - minC) / maxC) : 0.0h;
            half boost = half(mask.vibrance) * (1.0h - sat);
            adjusted = mix(half3(lum), adjusted, 1.0h + boost);
        }

        rgb = mix(rgb, adjusted, half(weight));
    }

    // 6. Gamut-clip soft proof: simulate target gamut by clamping out-of-gamut values
    //    In HDR mode, only clamp negative values (out-of-gamut chromaticity) — values > 1.0
    //    represent HDR brightness, not out-of-gamut colors, so the upper bound stays unclamped.
    bool isHDRGamut = (params.activeFlags & (1u << 4)) != 0;
    half3 gamutHi = isHDRGamut ? half3(65504.0h) : half3(1.0h);
    float3 gamutHiF = isHDRGamut ? float3(65504.0) : float3(1.0);
    if (params.gamutClipMode == 1) {
        // sRGB: clamp (working space IS extended linear sRGB)
        rgb = clamp(rgb, half3(0), gamutHi);
    } else if (params.gamutClipMode == 2) {
        // Display P3: sRGB -> P3, clamp, P3 -> sRGB
        float3 p3 = sRGBtoP3_edit * float3(rgb);
        rgb = half3(P3toSRGB_edit * clamp(p3, 0.0, gamutHiF));
    } else if (params.gamutClipMode == 3) {
        // Rec.2020: sRGB -> Rec.2020, clamp, Rec.2020 -> sRGB
        float3 r2020 = sRGBtoRec2020_edit * float3(rgb);
        rgb = half3(Rec2020toSRGB_edit * clamp(r2020, 0.0, gamutHiF));
    } else if (params.gamutClipMode == 4) {
        // Adobe RGB: sRGB -> Adobe RGB, clamp, Adobe RGB -> sRGB
        float3 aRgb = sRGBtoAdobeRGB_edit * float3(rgb);
        rgb = half3(AdobeRGBtoSRGB_edit * clamp(aRgb, 0.0, gamutHiF));
    }

    destination.write(half4(rgb, color.a), gid);
}
