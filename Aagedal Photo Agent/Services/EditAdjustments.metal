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
                            // bit5=blacks, bit6=saturation, bit7=vibrance,
                            // bit8=anonymizer (replaces the other tonal bits when set),
                            // bit9=temperature, bit10=tint
    float anonymizerAmount;   // 0-1 strength, gated by activeFlags bit8
    float anonymizerBlackOut; // 0 or 1 — full opaque redaction instead of the layered effect
    float temperature;       // -1..1, local white balance warm/cool shift
    float tint;              // -1..1, local white balance green/magenta shift
    float cornerRadius;      // 1 = ACR ellipse, 0 = Photo Agent rectangle
    uint  maskType;          // 0 = analytic ellipse, 1 = raster alpha, 2 = full-frame adjustment
    uint  brushLayer;        // slice index into the brush alpha array (maskType == 1 only)
};

/// Per-instance watermark-layer parameters. `center`/`halfExtent` are UV (display frame,
/// already aspect-corrected on the CPU side via WatermarkGeometry.renderedHalfExtentUV, so
/// the shader needs no extra aspect term). `textureLayer` indexes the shared watermark
/// texture array (deduped by library asset — several layers may reuse one slice).
struct WatermarkParams {
    float2 center;
    float2 halfExtent;
    float opacity;
    uint textureLayer;
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
    float globalDensity;     // -1..1, positive = denser/darker
    float vibrance;          // -1..1
    float saturation;        // 0..2 (1=identity)
    uint gamutClipMode;      // 0=off, 1=sRGB, 2=P3, 3=Rec2020

    float sharpness;         // 0..1 (ACR amount 0..150)
    float clarity;           // -1..1
    float dehaze;            // -1..1
    float _padDetail;

    float3x3 whiteBalanceMatrix; // Bradford chromatic adaptation (identity if no WB)

    uint activeFlags;        // bitmask: bit0=toneLUT, bit1=vibrance,
                             // bit2=saturation, bit3=whiteBalance, bit4=hdrMode,
                             // bit5=anonymizer (global), bit6=globalDensity,
                             // bit7=source has scene-referred HDR headroom,
                             // bit8=sharpness, bit9=clarity, bit10=dehaze
    uint maskCount;          // number of active masks (0-8)

    float2 scale;            // source→drawable scale (stretch-to-fill)
    float2 sourceSize;       // source texture dimensions
    float2 drawableSize;     // output drawable dimensions

    float2 viewportOrigin;   // top-left of visible region in normalized [0,1] source coords
    float2 viewportSize;     // fraction of source visible per axis (1,1 = full image)

    float lutDomainMin;      // -0.5 (extended range for color matrix overshoot)
    float lutDomainMax;      // 8.0 (HDR headroom ~1600 nits)

    float2 viewportCenter;   // crop center in normalized source coords (rotation pivot)
    float viewportRotation;  // radians; rotate sampling for clean-feed crop straighten
    float _padViewport;

    float2 cropHalfExtent;   // crop rect half-size as fraction of drawable, centered.
                             // (0.5,0.5) = no crop mask. Pixels beyond → background.

    uint orderCount;         // entries in the layer-order buffer (buffer 3); always ≥ 1
    float anonymizerAmount;   // 0-1 global slider strength, gated by activeFlags bit5
    float anonymizerBlackOut; // 0 or 1 — full opaque redaction instead of the layered effect

    int  maskOverlayIndex;    // mask buffer index to visualize, or -1 = none
    float maskOverlayOpacity; // 0-1 red-tint strength (matte mode replaces the image)

    uint watermarkCount;      // number of active watermark layers (0-4), see WatermarkParams
    uint watermarkFrame;      // 0 = source UV, 1 = crop-output UV
    uint useNearestNeighbor;  // shared viewer/editor display-scaling preference
    uint maskOverlayMode;     // 0 = red coverage tint, 1 = black/white matte preview

    uint orderOffset;         // first order-buffer entry for this compute segment
    uint executionFlags;      // bit0=intermediate, bit1=input in drawable frame,
                              // bit2=identity/full-source working frame
    uint _padExecution0;
    uint _padExecution1;

    float filmGrain;         // 0..1
    float filmHalation;      // 0..1
    float filmBloom;         // 0..1
    float filmVignette;      // 0..1
    float filmEdgeBlur;      // 0..1
    float filmGrainCoarseness; // 0..1, particle size
    float _padFilm1;
    float _padFilm2;
};

// ScopeShaders.metal consumes this same buffer through its ScopeEditParams mirror.
// Keep this assertion in sync with Swift's MemoryLayout<EditParams>.stride.
static_assert(sizeof(EditParams) == 256,
              "EditParams layout changed; update Swift and ScopeEditParams together");

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

inline float3 colorTransformToSRGB(float3 rgb, uint space) {
    switch (space) {
        case 1u: return P3toSRGB_edit * rgb;
        case 2u: return Rec2020toSRGB_edit * rgb;
        case 3u: return AdobeRGBtoSRGB_edit * rgb;
        default: return rgb;
    }
}

inline float3 colorTransformFromSRGB(float3 rgb, uint space) {
    switch (space) {
        case 1u: return sRGBtoP3_edit * rgb;
        case 2u: return sRGBtoRec2020_edit * rgb;
        case 3u: return sRGBtoAdobeRGB_edit * rgb;
        default: return rgb;
    }
}

inline half3 applyColorTransform(
    half3 input,
    constant MaskParams &node,
    texture2d_array<half, access::sample> colorLUTs
) {
    // activeFlags is repurposed by maskType 3: 1=LUT, 2=CST.
    if (node.activeFlags == 2u) {
        uint inputSpace = uint(max(node.temperature, 0.0));
        uint outputSpace = uint(max(node.tint, 0.0));
        float3 linearSRGB = colorTransformToSRGB(float3(input), inputSpace);
        return half3(colorTransformFromSRGB(linearSRGB, outputSpace));
    }

    float3 domainMin = float3(node.center, node.rotation);
    float3 domainMax = float3(node.radii, node.feather);
    float3 coord = clamp(
        (float3(input) - domainMin) / max(domainMax - domainMin, float3(0.000001)),
        0.0, 1.0
    );
    constexpr float cubeSize = 33.0;
    float2 sampleXY = (coord.rg * (cubeSize - 1.0) + 0.5) / cubeSize;
    float blue = coord.b * (cubeSize - 1.0);
    uint b0 = uint(floor(blue));
    uint b1 = min(b0 + 1u, 32u);
    float bt = blue - float(b0);
    constexpr sampler cubeSampler(filter::linear, address::clamp_to_edge);
    half3 low = colorLUTs.sample(cubeSampler, sampleXY, node.brushLayer + b0).rgb;
    half3 high = colorLUTs.sample(cubeSampler, sampleXY, node.brushLayer + b1).rgb;
    return mix(low, high, half(bt));
}

// ============================================================
// Layer nodes — global adjustments and per-mask adjustments are
// each factored into a device function so the kernel can apply
// them in a data-driven order (the global node is reorderable
// among the masks). Pulling a node out of the chain or moving it
// is a change to the order buffer, not the math.
// ============================================================

/// Global adjustment block: white balance → tone LUT (+highlight desat) → per-color HSL
/// → global density → vibrance → saturation → dehaze. Each step is gated by params.activeFlags, so an inactive
/// global node is a no-op. Returns the adjusted color.
static half3 applyGlobal(half3 rgb,
                         constant EditParams &params,
                         texture1d<float, access::sample> toneLUT,
                         constant HSLParams &hslParams)
{
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
        float desatHigh = isHDR ? 8.0  : 1.6;   // HDR ceiling ~1600 nits (+3 EV)
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
            // Sigma ~30° for primaries (≈71° FWHM), ~15° for skin tone.
            // Wide overlap between adjacent channels prevents harsh edges
            // at extreme slider values.
            float centers[7] = { 0.0, 60.0, 120.0, 180.0, 240.0, 300.0, 22.0 };
            float sigmas[7] = { 30.0, 30.0, 30.0, 30.0, 30.0, 30.0, 15.0 };

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

    // 3. Global Density — broad luminance density, preserving chroma.
    //    Positive slider = more dense = darker; negative = less dense = brighter.
    if (params.activeFlags & (1u << 6)) {
        float3 rgbF = float3(rgb);
        float Y = dot(rgbF, float3(0.2126, 0.7152, 0.0722));
        float3 colorChroma = rgbF - float3(Y);
        float gain = pow(2.0, -params.globalDensity);
        float Y_new = max(Y * gain, 0.0);
        rgb = half3(max(float3(Y_new) + colorChroma, 0.0));
    }

    // 4. Vibrance: selective saturation boost on less-saturated pixels
    if (params.activeFlags & (1u << 1)) {
        half lum = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
        half maxC = max3(rgb.r, rgb.g, rgb.b);
        half minC = min3(rgb.r, rgb.g, rgb.b);
        half sat = (maxC > (half)0.001) ? ((maxC - minC) / maxC) : (half)0.0;
        half boost = (half)params.vibrance * ((half)1.0 - sat);
        rgb = mix(half3(lum), rgb, (half)1.0 + boost);
    }

    // 5. Saturation — exact match to CIColorControls saturation
    if (params.activeFlags & (1u << 2)) {
        half lum = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
        rgb = mix(half3(lum), rgb, (half)params.saturation);
    }

    // 6. Dehaze — invert a neutral atmospheric veil estimated from the pixel's
    // dark channel. Negative values run the forward model to add a soft veil.
    // This stays inside the global layer because it needs no neighbouring pixels.
    if (params.activeFlags & (1u << 10)) {
        float3 rgbF = max(float3(rgb), 0.0);
        if (params.dehaze > 0.0) {
            float darkChannel = clamp(min3(rgbF.r, rgbF.g, rgbF.b), 0.0, 1.0);
            float transmission = clamp(1.0 - params.dehaze * 0.72 * darkChannel, 0.35, 1.0);
            rgbF = max((rgbF - float3(1.0 - transmission)) / transmission, 0.0);
        } else {
            float veil = -params.dehaze * 0.35;
            rgbF = rgbF * (1.0 - veil) + float3(veil);
        }
        rgb = half3(rgbF);
    }

    return rgb;
}

/// Spatial detail stage for the global node. It samples only source luminance, then applies
/// that high-frequency/local-contrast signal to the running (already color-corrected) pixel,
/// preserving the edited chroma. The source texture always has mipmaps in both live and export
/// paths, so Clarity can use a resolution-relative neighbourhood without a costly large kernel.
static half3 applySpatialDetail(half3 rgb,
                                constant EditParams &params,
                                texture2d<half, access::sample> source,
                                float2 uv)
{
    constexpr sampler detailSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 sourceCenter = max(float3(source.sample(detailSampler, uv, level(0.0)).rgb), 0.0);
    float sourceY = dot(sourceCenter, float3(0.2126, 0.7152, 0.0722));
    float3 rgbF = max(float3(rgb), 0.0);

    // Clarity: medium-radius local contrast, concentrated in the midtones. The mip level is
    // derived from image size so the visual scale is stable between preview and full export.
    if (params.activeFlags & (1u << 9)) {
        float shortSide = max(min(params.sourceSize.x, params.sourceSize.y), 1.0);
        float radiusPx = clamp(shortSide * 0.008, 8.0, 64.0);
        float maxLevel = float(source.get_num_mip_levels() - 1);
        float mipLevel = clamp(log2(radiusPx), 0.0, maxLevel);
        float3 localAverage = max(float3(source.sample(detailSampler, uv, level(mipLevel)).rgb), 0.0);
        float localY = dot(localAverage, float3(0.2126, 0.7152, 0.0722));
        float currentY = dot(rgbF, float3(0.2126, 0.7152, 0.0722));
        float midtoneWeight = smoothstep(0.02, 0.22, currentY)
            * (1.0 - smoothstep(0.72, 1.35, currentY));
        // Keep the -100...100 slider useful across its full range. A 0.75 gain gives
        // typical +15...+30 edits a restrained midtone lift instead of a crunchy halo.
        float targetY = max(currentY + (sourceY - localY) * params.clarity * 0.75 * midtoneWeight, 0.0);
        float luminanceScale = clamp(targetY / max(currentY, 0.001), 0.0, 4.0);
        rgbF *= luminanceScale;
    }

    // Sharpness: a compact cross-shaped unsharp mask. At fit-to-view, one drawable pixel can
    // cover several source pixels; using that footprint keeps the effect visible instead of
    // letting the final reduction average away a fixed one-source-pixel halo. At 100% view and
    // full-resolution export the footprint clamps to exactly one source pixel.
    if (params.activeFlags & (1u << 8)) {
        float2 sourcePixelsPerDrawable = params.viewportSize * params.sourceSize
            / max(params.drawableSize, float2(1.0));
        float2 texel = max(sourcePixelsPerDrawable, float2(1.0))
            / max(params.sourceSize, float2(1.0));
        float north = dot(float3(source.sample(detailSampler, uv + float2(0.0, -texel.y), level(0.0)).rgb), float3(0.2126, 0.7152, 0.0722));
        float south = dot(float3(source.sample(detailSampler, uv + float2(0.0,  texel.y), level(0.0)).rgb), float3(0.2126, 0.7152, 0.0722));
        float west  = dot(float3(source.sample(detailSampler, uv + float2(-texel.x, 0.0), level(0.0)).rgb), float3(0.2126, 0.7152, 0.0722));
        float east  = dot(float3(source.sample(detailSampler, uv + float2( texel.x, 0.0), level(0.0)).rgb), float3(0.2126, 0.7152, 0.0722));
        float blurredY = (sourceY * 4.0 + north + south + west + east) * 0.125;
        float highPass = sourceY - blurredY;
        // Reject only nearly-flat numerical/sensor variation. ACR's 0...150 range is expected
        // to progress from a restrained edge lift to deliberately strong sharpening; the
        // compact cross kernel produces half the high-pass of a conventional 3x3 Gaussian,
        // so a 6x maximum gain corresponds to roughly 300% conventional unsharp-mask amount.
        float edgeGate = smoothstep(0.0001, 0.001, abs(highPass));
        rgbF = max(rgbF + float3(highPass * params.sharpness * 6.0 * edgeGate), 0.0);
    }

    return half3(rgbF);
}

/// Gaussian feather for an analytic shape. The stored outline remains the editable nominal
/// outline, but is a 10%-coverage contour whenever feathering is active rather than a hard zero
/// boundary. The low-valued tail therefore continues outside the handles and becomes visually
/// negligible before it underflows, avoiding a finite rim in the matte.
static float analyticFeatherCoverage(float dist, float feather)
{
    float f = clamp(feather, 0.0, 1.0);
    if (f <= 0.0) return dist <= 1.0 ? 1.0 : 0.0;
    float inner = 1.0 - f;
    if (dist <= inner) return 1.0;
    float t = (dist - inner) / f;
    return exp2(-3.32192809489 * t * t); // 10^(-t²): 10% at the nominal outline
}

/// Exact gauge for Photo Agent's rounded-rectangle extension in the analytic mask's normalized
/// local frame. Its level sets are scaled copies of the nominal outline, so feathering preserves
/// the selected corner proportion instead of exposing a Euclidean SDF's diagonal medial axes.
/// radius=1 is exactly the ACR ellipse (`length(p)`); radius=0 is a sharp rectangle
/// (`max(abs(p).x, abs(p).y)`). Intermediate values use elliptical corners after the normalized
/// shape is stretched by the mask's two independent semi-axes.
static float roundedRectangleGauge(float2 p, float radius)
{
    float r = clamp(radius, 0.0, 1.0);
    float straight = 1.0 - r;
    float2 a = abs(p);
    float major = max(a.x, a.y);
    float minor = min(a.x, a.y);

    // Rays near either axis meet a straight side at major=1.
    if (minor <= straight * major) return major;

    // Corner rays meet the radius-r circle around (straight, straight). Solve that ray/circle
    // intersection once, then express p as a fraction of the resulting boundary radius.
    float radial = length(a);
    float2 direction = a / max(radial, 1e-7);
    float directionSum = direction.x + direction.y;
    float discriminant = straight * straight * directionSum * directionSum
        - (2.0 * straight * straight - r * r);
    float boundaryRadius = straight * directionSum + sqrt(max(discriminant, 0.0));
    return radial / max(boundaryRadius, 1e-7);
}

/// Analytical ellipse/rounded-rectangle coverage at `uv` (0 = outside / no effect). mask.radii
/// carries ACR's SIGNED oriented-corner box half-extents (see EllipseMaskGeometry):
/// un-rotating the aspect-corrected corner vector recovers the true semi-axes. All
/// rotation happens in aspect-corrected (pixel) space — raw-UV rotation would shear the
/// shape by the image aspect ratio. Includes inversion, but not adjustment-layer amount so the
/// same coverage can drive a true black/white mask matte. ACR ignores `cornerRadius` and sees
/// the same oriented box as its standard CircularGradient ellipse fallback.
static float analyticMaskCoverage(constant MaskParams &mask, float2 uv, float2 sourceSize)
{
    float maskAspect = sourceSize.y > 0.0 ? sourceSize.x / sourceSize.y : 1.0;
    float cosR = cos(mask.rotation);
    float sinR = sin(mask.rotation);
    float2 corner = mask.radii * float2(maskAspect, 1.0);
    float2 ab = float2(corner.x * cosR + corner.y * sinR, -corner.x * sinR + corner.y * cosR);
    if (ab.x <= 0.0 || ab.y <= 0.0) return 0.0;   // degenerate — ACR renders nothing
    float2 d = (uv - mask.center) * float2(maskAspect, 1.0);
    float2 local = float2(d.x * cosR + d.y * sinR, -d.x * sinR + d.y * cosR);
    float dist = roundedRectangleGauge(local / ab, mask.cornerRadius);
    float weight = analyticFeatherCoverage(dist, mask.feather);
    if (mask.inverted > 0.5) weight = 1.0 - weight;
    return weight;
}

static float maskWeight(constant MaskParams &mask, float2 uv, float2 sourceSize)
{
    return analyticMaskCoverage(mask, uv, sourceSize) * mask.amount;
}

/// Alpha-composites one watermark layer over the running color, "over"-blending in
/// premultiplied space (the texture is decoded/uploaded premultiplied — see
/// `MetalEditPipeline.loadWatermarkTextures` — so no separate un-premultiply/re-premultiply
/// step is needed). `wm.center`/`halfExtent` define the watermark's footprint in UV; a pixel
/// outside it is returned unchanged. Degenerate (zero) `halfExtent` — e.g. the layer's
/// library asset went missing — also returns `rgb` unchanged rather than dividing by zero.
static half3 applyWatermark(half3 rgb, constant WatermarkParams &wm,
                            texture2d_array<half, access::sample> tex, float2 uv)
{
    if (wm.halfExtent.x <= 0.0 || wm.halfExtent.y <= 0.0) return rgb;
    float2 local = (uv - wm.center) / wm.halfExtent;
    if (abs(local.x) > 1.0 || abs(local.y) > 1.0) return rgb;
    float2 sampleUV = local * 0.5 + 0.5;
    constexpr sampler wmSampler(filter::linear, address::clamp_to_edge);
    half4 wmColor = tex.sample(wmSampler, sampleUV, wm.textureLayer);
    half opacity = half(wm.opacity);
    half alpha = wmColor.a * opacity;
    return wmColor.rgb * opacity + rgb * (1.0h - alpha);
}

/// Per-mask local tonal adjustments applied to `rgb` (returns the fully-adjusted color;
/// the kernel blends it back by the mask weight). Each adjustment is gated by mask.activeFlags.
static half3 applyMaskColor(half3 rgb, constant MaskParams &mask)
{
    half3 adjusted = rgb;

    // Local white balance (Temperature/Tint): a lightweight multiplicative RGB gain, not
    // the full Bradford chromatic-adaptation matrix the global WB uses — that requires a
    // per-mask CPU CIContext render to derive, which doesn't belong in a GPU-resident,
    // per-pixel mask function. Applied first, matching ACR's Local panel ordering (WB
    // before tonal adjustments) and the global chain's own WB-before-tone order.
    if (mask.activeFlags & (1u << 9)) {
        // Warm (positive) boosts red / cuts blue; cool (negative) the reverse.
        adjusted.r *= half(1.0 + mask.temperature * 0.3);
        adjusted.b *= half(1.0 - mask.temperature * 0.3);
    }
    if (mask.activeFlags & (1u << 10)) {
        // Magenta (positive) cuts green; green (negative) boosts it — matches Adobe's Tint sign.
        adjusted.g *= half(1.0 - mask.tint * 0.3);
    }

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

    return adjusted;
}

/// Roll scene-referred super-whites into the SDR display range. This is an output transform,
/// not an adjustment-layer operation: applying it only after the full chain preserves highlight
/// differences for a later masked layer to pull back below the shoulder.
static float sdrOutputToneMap(float x)
{
    if (x <= 0.7) return x;
    float t = min((x - 0.7) / 0.9, 1.0);
    float u = t - 1.0;
    return 1.0 + 0.3 * u * u * u;
}

struct AnonymizerShape {
    float distortAmountPx;
    float distortScalePx;
    float blurRadiusPx;
    float mosaicSizePx;
};

static uint anonymizerIHash(uint x)
{
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

static float anonymizerRand01(int ix, int iy, uint seed, uint channel)
{
    uint h = anonymizerIHash(uint(ix) * 0x9E3779B1u
                             ^ uint(iy) * 0x85EBCA77u
                             ^ seed * 0xC2B2AE3Du
                             ^ channel * 0x27D4EB2Fu);
    return float(h) * (1.0 / 4294967295.0);
}

static float anonymizerSmoothT(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

static float anonymizerVNoise(float px, float py, uint seed, uint channel)
{
    float fx = floor(px);
    float fy = floor(py);
    int ix = int(fx);
    int iy = int(fy);
    float tx = anonymizerSmoothT(px - fx);
    float ty = anonymizerSmoothT(py - fy);
    float a = anonymizerRand01(ix,     iy,     seed, channel);
    float b = anonymizerRand01(ix + 1, iy,     seed, channel);
    float c = anonymizerRand01(ix,     iy + 1, seed, channel);
    float d = anonymizerRand01(ix + 1, iy + 1, seed, channel);
    float ab = a + (b - a) * tx;
    float cd = c + (d - c) * tx;
    return ab + (cd - ab) * ty;
}

/// Maps the app's single 0-1 amount slider onto the same 1080p-short-side pixel-space
/// family as the standalone Multi-Layer Anonymizer: random distortion, Gaussian blur,
/// then mosaic. The app still evaluates it in one shader sample so global and per-mask
/// anonymizers remain cheap enough for live masked editing.
static AnonymizerShape anonymizerShape(float strength, float2 sourceSize)
{
    float t = clamp(strength, 0.0, 1.0);
    float shortSide = max(min(sourceSize.x, sourceSize.y), 1.0);
    float resolutionScale = shortSide / 1080.0;
    float mosaicBase = mix(4.0, 128.0, t * t);
    AnonymizerShape shape;
    shape.mosaicSizePx = max(mosaicBase * resolutionScale, 3.0);
    shape.blurRadiusPx = max(shape.mosaicSizePx * 0.6, 1.0);
    shape.distortAmountPx = max(shape.mosaicSizePx * 0.6, 1.0);
    shape.distortScalePx = max(shape.mosaicSizePx * 0.4, 2.0);
    return shape;
}

/// Anonymizer base-color sampler: approximates the standalone effect's
/// distort -> Gaussian blur -> mosaic stack in one texture fetch. The square mosaic cell
/// is resolved first; the cell center is spatially distorted by the same deterministic
/// value-noise family as the plugin; blur is provided by the source texture's mip chain.
static half3 sampleAnonymized(texture2d<half, access::sample> source,
                              float2 uv,
                              float2 sourceSize,
                              AnonymizerShape shape)
{
    constexpr sampler mipSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 px = uv * sourceSize;
    float b = max(shape.mosaicSizePx, 1.0);
    float2 blockOrigin = floor(px / b) * b;
    float2 samplePx = min(blockOrigin + b * 0.5, sourceSize - 1.0);

    uint seed = anonymizerIHash(0x5BD1E995u);
    float invScale = 1.0 / max(shape.distortScalePx, 2.0);
    float nx = anonymizerVNoise(samplePx.x * invScale, samplePx.y * invScale, seed, 0u);
    float ny = anonymizerVNoise(samplePx.x * invScale, samplePx.y * invScale, seed, 1u);
    float2 displacement = (float2(nx, ny) * 2.0 - 1.0) * shape.distortAmountPx;
    float2 sampleUV = clamp((samplePx + displacement) / sourceSize, 0.0, 1.0);

    float maxLevel = float(source.get_num_mip_levels() - 1);
    float mipLevel = clamp(log2(max(shape.blurRadiusPx * 2.0, 1.0)), 0.0, maxLevel);
    return source.sample(mipSampler, sampleUV, level(mipLevel)).rgb;
}

/// A small, explicitly sampled blur used by the optical edge-softness effect. Sampling a very
/// coarse mip level directly made strong settings reveal square mip texels, especially on
/// previews. These concentric taps keep the blur continuous while a modest mip level handles the
/// fine detail inside each sample footprint.
static float3 sampleFilmEdgeBlur(
    texture2d<half, access::sample> source,
    float2 uv,
    float2 sourceSize,
    float strength
) {
    constexpr sampler blurSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float minimumDimension = max(min(sourceSize.x, sourceSize.y), 1.0);
    float radiusPixels = mix(1.5, minimumDimension * 0.022, strength * strength);
    float2 radius = radiusPixels / max(sourceSize, float2(1.0));
    float maxLevel = float(source.get_num_mip_levels() - 1);
    float lod = clamp(mix(0.5, 2.5, strength), 0.0, maxLevel);

    float3 result = float3(source.sample(blurSampler, uv, level(lod)).rgb) * 0.16;
    float2 inner = radius * 0.45;
    result += float3(source.sample(blurSampler, uv + float2( inner.x, 0.0), level(lod)).rgb) * 0.09;
    result += float3(source.sample(blurSampler, uv + float2(-inner.x, 0.0), level(lod)).rgb) * 0.09;
    result += float3(source.sample(blurSampler, uv + float2(0.0,  inner.y), level(lod)).rgb) * 0.09;
    result += float3(source.sample(blurSampler, uv + float2(0.0, -inner.y), level(lod)).rgb) * 0.09;

    float2 diagonal = radius * 0.55;
    result += float3(source.sample(blurSampler, uv + float2( diagonal.x,  diagonal.y), level(lod)).rgb) * 0.07;
    result += float3(source.sample(blurSampler, uv + float2(-diagonal.x,  diagonal.y), level(lod)).rgb) * 0.07;
    result += float3(source.sample(blurSampler, uv + float2( diagonal.x, -diagonal.y), level(lod)).rgb) * 0.07;
    result += float3(source.sample(blurSampler, uv + float2(-diagonal.x, -diagonal.y), level(lod)).rgb) * 0.07;

    result += float3(source.sample(blurSampler, uv + float2( radius.x, 0.0), level(lod)).rgb) * 0.05;
    result += float3(source.sample(blurSampler, uv + float2(-radius.x, 0.0), level(lod)).rgb) * 0.05;
    result += float3(source.sample(blurSampler, uv + float2(0.0,  radius.y), level(lod)).rgb) * 0.05;
    result += float3(source.sample(blurSampler, uv + float2(0.0, -radius.y), level(lod)).rgb) * 0.05;
    return result;
}

/// Film-emulation finishing pass. Spatial effects sample the mipmapped texture containing
/// the complete upstream layer composite; the render-plan compiler isolates Global whenever
/// Halation, Bloom, or Edge Blur is active. Grain and vignette remain pointwise.
static half3 applyFilmEmulation(
    half3 input,
    texture2d<half, access::sample> source,
    float2 inputUV,
    float2 sourceSize,
    constant EditParams &params
) {
    float3 rgb = float3(input);
    constexpr sampler mipSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float maxLevel = float(source.get_num_mip_levels() - 1);

    if (params.filmEdgeBlur > 0.0) {
        float3 blurred = sampleFilmEdgeBlur(
            source, inputUV, sourceSize, params.filmEdgeBlur
        );
        float2 edgeCoord = abs(inputUV - 0.5) * 2.0;
        float edge = smoothstep(mix(0.90, 0.46, params.filmEdgeBlur), 1.0,
                                max(edgeCoord.x, edgeCoord.y));
        rgb = mix(rgb, blurred, edge * params.filmEdgeBlur);
    }

    if (params.filmBloom > 0.0) {
        float mipLevel = clamp(mix(3.5, 7.0, params.filmBloom), 0.0, maxLevel);
        float3 blurred = float3(source.sample(mipSampler, inputUV, level(mipLevel)).rgb);
        float3 glow = max(blurred - 0.35, 0.0);
        rgb += glow * (0.28 * params.filmBloom);
    }

    if (params.filmHalation > 0.0) {
        float mipLevel = clamp(mix(3.0, 6.0, params.filmHalation), 0.0, maxLevel);
        float3 blurred = float3(source.sample(mipSampler, inputUV, level(mipLevel)).rgb);
        float blurredLuma = dot(blurred, float3(0.2126, 0.7152, 0.0722));
        float currentLuma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float halo = max(blurredLuma - currentLuma * 0.55 - 0.12, 0.0);
        rgb += float3(1.0, 0.20, 0.035) * halo * (0.55 * params.filmHalation);
    }

    if (params.filmVignette != 0.0) {
        float2 centered = (inputUV - 0.5) * 2.0;
        float radial = length(centered) * 0.70710678;
        float absVal = abs(params.filmVignette);
        float vignette = smoothstep(mix(0.92, 0.05, absVal), 1.0, radial);
        float amount = (0.80 * absVal + 0.60 * absVal * absVal);
        if (params.filmVignette > 0.0) {
            rgb *= 1.0 + vignette * amount;
        } else {
            rgb *= 1.0 - vignette * amount;
        }
    }

    if (params.filmGrain > 0.0) {
        // Film density varies in softly clustered grains built from two fine emulsion layers
        // plus a weaker broad clump. `filmGrainCoarseness` sets particle size independently of
        // Grain amount, matching Camera Raw's separate Amount/Size controls.
        float2 pixel = inputUV * max(sourceSize, float2(1.0));
        float grainScale = mix(0.9, 3.4, params.filmGrainCoarseness);
        float fineA = anonymizerVNoise(
            pixel.x / grainScale, pixel.y / grainScale, 0xA341316Cu, 0u
        ) * 2.0 - 1.0;
        float fineB = anonymizerVNoise(
            pixel.x / grainScale + 19.7, pixel.y / grainScale - 7.3, 0xC8013EA4u, 1u
        ) * 2.0 - 1.0;
        float clump = anonymizerVNoise(
            pixel.x / (grainScale * 2.5), pixel.y / (grainScale * 2.5), 0xAD90777Du, 2u
        ) * 2.0 - 1.0;
        float lumaNoise = fineA * 0.42 + fineB * 0.42 + clump * 0.22;

        // Colour negative grain isn't perfectly monochrome: each dye layer develops its own
        // pattern. Blending in a little decorrelated per-channel noise reads as color-film
        // speckle instead of a flat grey digital overlay.
        float3 chroma = float3(
            anonymizerVNoise(pixel.x / grainScale + 3.1, pixel.y / grainScale + 8.2, 0xE1B3A57Fu, 3u),
            anonymizerVNoise(pixel.x / grainScale - 5.4, pixel.y / grainScale + 2.7, 0x7C5F9E21u, 4u),
            anonymizerVNoise(pixel.x / grainScale + 11.0, pixel.y / grainScale - 9.3, 0x2A9D3B6Eu, 5u)
        ) * 2.0 - 1.0;
        float3 noise = mix(float3(lumaNoise), chroma, 0.22);

        float luma = max(dot(rgb, float3(0.2126, 0.7152, 0.0722)), 0.0);
        // Grain reads densest in shadows and midtones and thins through the highlights, the
        // way silver-halide grain behaves in a print, rather than peaking symmetrically at
        // mid-gray and vanishing equally toward both black and white.
        float response = mix(1.0, 0.18, smoothstep(0.05, 0.95, clamp(luma, 0.0, 1.0)));
        rgb *= exp2(noise * response * (0.85 * params.filmGrain));
    }

    return half3(max(rgb, 0.0));
}

kernel void editAdjustments(
    texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    texture1d<float, access::sample> toneLUT [[texture(2)]],
    texture2d_array<half, access::sample> brushAlpha [[texture(3)]],
    texture2d_array<half, access::sample> watermarkTex [[texture(4)]],
    texture2d_array<half, access::sample> colorLUTs [[texture(5)]],
    constant EditParams &params [[buffer(0)]],
    constant MaskParams *masks [[buffer(1)]],
    constant HSLParams &hslParams [[buffer(2)]],
    constant uint *order [[buffer(3)]],
    constant WatermarkParams *watermarks [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.drawableSize.x) || gid.y >= uint(params.drawableSize.y)) {
        return;
    }

    bool intermediatePass = (params.executionFlags & (1u << 0)) != 0;
    bool inputInDrawableFrame = (params.executionFlags & (1u << 1)) != 0;
    bool identitySourceFrame = (params.executionFlags & (1u << 2)) != 0;

    // Map drawable pixel through viewport to source UV. Full-source intermediate passes use
    // identity coordinates so their textures remain stable across preview zoom/pan changes.
    float2 drawableNorm = float2(gid) / params.drawableSize;

    // Crop mask: black out (background) outside the confirmed crop rectangle. The viewport
    // letterbox-fits the crop, so the margin between the crop rect and the drawable edge
    // still samples in-bounds image — this is what actually "cuts" the crop. (0.5,0.5) ⇒
    // no mask (full-image render).
    if (!identitySourceFrame) {
        float2 cropCentered = drawableNorm - 0.5;
        if (abs(cropCentered.x) > params.cropHalfExtent.x ||
            abs(cropCentered.y) > params.cropHalfExtent.y) {
            destination.write(half4(0.0197, 0.0197, 0.0197, 1), gid);
            return;
        }
    }

    float2 uv;
    if (identitySourceFrame) {
        uv = drawableNorm;
    } else if (params.viewportRotation != 0.0) {
        // Clean-feed crop straighten: rotate the centered offset around the crop center.
        // Rotation must happen in pixel space (sourceSize) so it isn't skewed by the
        // image's aspect ratio, then convert back to normalized UV.
        float2 off = (drawableNorm - 0.5) * params.viewportSize * params.sourceSize;
        float c = cos(params.viewportRotation);
        float s = sin(params.viewportRotation);
        float2 r = float2(off.x * c - off.y * s, off.x * s + off.y * c);
        uv = params.viewportCenter + r / params.sourceSize;
    } else {
        uv = params.viewportOrigin + drawableNorm * params.viewportSize;
    }

    // Letterbox: dark gray for pixels outside source bounds
    // 0.0197 linear ≈ sRGB 0.15, matching SwiftUI previewBackground
    if (uv.x < 0.0 || uv.x >= 1.0 || uv.y < 0.0 || uv.y >= 1.0) {
        destination.write(half4(0.0197, 0.0197, 0.0197, 1), gid);
        return;
    }

    // An intermediate rendered in the output/crop frame is sampled by drawable UV. A
    // full-source intermediate (and the original source) is sampled by source UV.
    float2 inputUV = inputInDrawableFrame ? drawableNorm : uv;
    float2 inputTextureSize = float2(source.get_width(), source.get_height());
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    constexpr sampler nearestNeighbor(filter::nearest, address::clamp_to_edge);
    half4 color = params.useNearestNeighbor != 0u
        ? source.sample(nearestNeighbor, inputUV)
        : source.sample(bilinear, inputUV);
    half3 rgb = color.rgb;

    // Spatial detail samples the original source. Track any redaction or watermark that has
    // already replaced the running pixel before the global node, so sharpening/clarity cannot
    // reintroduce underlying detail into that protected region.
    float spatialDetailProtection = 0.0;

    // Layer chain: apply each node in the order given by the order buffer. The global
    // adjustment block (kGlobalOrderSentinel) is reorderable among the masks — every node
    // transforms the running color in sequence, so moving the global node before/after a
    // mask changes the result. Legacy edits resolve to [global, mask0, mask1, …], which
    // reproduces the previous fixed "global first, then masks" behavior exactly.
    //
    // Order-buffer entry encoding (3 buckets): 0xFFFFFFFF = global sentinel; the top bit
    // (0x80000000) set on anything else = a watermark-layer index (low 31 bits) into
    // `watermarks`; otherwise it's a plain mask index into `masks` (< maskCount). The global
    // sentinel is checked FIRST since it also has the top bit set.
    for (uint k = 0; k < params.orderCount; k++) {
        uint entry = order[params.orderOffset + k];
        if (entry == 0xFFFFFFFFu) {
            // Global node: the order buffer uses 0xFFFFFFFF as the global sentinel
            // (MetalEditPipeline.globalOrderSentinel). Anonymization belongs to this node:
            // the render-plan compiler isolates it so `source` is the complete upstream
            // composite rather than the original image.
            bool globalAnonActive = (params.activeFlags & (1u << 5)) != 0;
            if (globalAnonActive) {
                spatialDetailProtection = 1.0;
                if (params.anonymizerBlackOut > 0.5) {
                    // Global Black Out is terminal. Do not let a later tone operation lift
                    // the protected image away from absolute black.
                    destination.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
                    return;
                } else {
                    AnonymizerShape anonShape = anonymizerShape(
                        params.anonymizerAmount, inputTextureSize
                    );
                    rgb = sampleAnonymized(source, inputUV, inputTextureSize, anonShape);
                }
            }
            rgb = applyGlobal(rgb, params, toneLUT, hslParams);
            if (params.activeFlags & ((1u << 8) | (1u << 9))) {
                half3 detailed = applySpatialDetail(rgb, params, source, inputUV);
                rgb = mix(rgb, detailed, half(1.0 - clamp(spatialDetailProtection, 0.0, 1.0)));
            }
            rgb = applyFilmEmulation(rgb, source, inputUV, inputTextureSize, params);
        } else if (entry & 0x80000000u) {
            uint wIdx = entry & 0x7FFFFFFFu;
            if (wIdx < params.watermarkCount) {
                float2 watermarkUV = uv;
                if (params.watermarkFrame == 1u) {
                    float2 cropMin = 0.5 - params.cropHalfExtent;
                    float2 cropSize = max(params.cropHalfExtent * 2.0, float2(0.000001));
                    watermarkUV = (drawableNorm - cropMin) / cropSize;
                }
                float2 wmLocal = (watermarkUV - watermarks[wIdx].center)
                    / max(watermarks[wIdx].halfExtent, float2(0.000001));
                if (abs(wmLocal.x) <= 1.0 && abs(wmLocal.y) <= 1.0) {
                    spatialDetailProtection = max(
                        spatialDetailProtection, clamp(watermarks[wIdx].opacity, 0.0, 1.0)
                    );
                }
                rgb = applyWatermark(rgb, watermarks[wIdx], watermarkTex, watermarkUV);
            }
        } else {
            constant MaskParams &mask = masks[entry];
            if (mask.maskType == 3u) {
                half3 transformed = applyColorTransform(rgb, mask, colorLUTs);
                rgb = mix(rgb, transformed, half(clamp(mask.amount, 0.0, 1.0)));
                continue;
            }
            // Brush masks resolve their coverage from the pre-rasterized alpha array (sampled
            // in source UV space); ellipse masks use the analytic SDF. `applyMaskColor` below
            // is identical for both — it only ever sees a resolved weight + rgb.
            float weight;
            if (mask.maskType == 2u) {
                weight = mask.amount;
            } else if (mask.maskType == 1u) {
                constexpr sampler brushSampler(filter::linear, address::clamp_to_edge);
                weight = float(brushAlpha.sample(brushSampler, uv, mask.brushLayer).r);
                if (mask.inverted > 0.5) weight = 1.0 - weight;
                weight *= mask.amount;
            } else {
                weight = maskWeight(mask, uv, params.sourceSize);
            }
            if (weight < 0.001) continue;
            half3 adjusted;
            if (mask.activeFlags & (1u << 8)) {
                spatialDetailProtection = max(spatialDetailProtection, clamp(weight, 0.0, 1.0));
                // The render-plan compiler isolates this node, so the input texture already
                // contains every upstream global/mask/watermark. Sample that composite, apply
                // this mask's own tonal controls, then let later passes process the result.
                if (mask.anonymizerBlackOut > 0.5) {
                    adjusted = half3(0.0h, 0.0h, 0.0h);
                } else {
                    AnonymizerShape anonShape = anonymizerShape(
                        mask.anonymizerAmount, inputTextureSize
                    );
                    adjusted = sampleAnonymized(
                        source, inputUV, inputTextureSize, anonShape
                    );
                    adjusted = applyMaskColor(adjusted, mask);
                }
            } else {
                adjusted = applyMaskColor(rgb, mask);
            }
            rgb = mix(rgb, adjusted, half(weight));
        }
    }

    if (!intermediatePass) {
        // Final SDR output transform for scene-referred sources. It must remain after every
        // layer, so multi-pass execution applies it only in the presentation dispatch.
        bool sourceHasHeadroom = (params.activeFlags & (1u << 7)) != 0;
        bool hdrEditMode = (params.activeFlags & (1u << 4)) != 0;
        if (sourceHasHeadroom && !hdrEditMode) {
            float3 rgbF = float3(rgb);
            rgbF.r = sdrOutputToneMap(rgbF.r);
            rgbF.g = sdrOutputToneMap(rgbF.g);
            rgbF.b = sdrOutputToneMap(rgbF.b);
            rgb = half3(rgbF);
        }

        // Gamut-clip soft proof: simulate target gamut by clamping out-of-gamut values.
        // In HDR mode, only clamp negative values (out-of-gamut chromaticity) — values > 1.0
        // represent HDR brightness, not out-of-gamut colors, so the upper bound stays unclamped.
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

        // Selected-mask visualization. Normal paint mode uses an ACR-style red tint for an
        // otherwise unadjusted mask; hovering a mask-type icon switches to a black/white coverage
        // matte. The latter includes inversion and feather/brush softness while remaining
        // independent of adjustment opacity, so the fully selected region stays white.
        if (params.maskOverlayIndex >= 0 && uint(params.maskOverlayIndex) < params.maskCount) {
            constant MaskParams &om = masks[params.maskOverlayIndex];
            float ow;
            if (om.maskType == 2u || om.maskType == 3u) {
                ow = 1.0;
            } else if (om.maskType == 1u) {
                constexpr sampler brushSampler(filter::linear, address::clamp_to_edge);
                ow = float(brushAlpha.sample(brushSampler, uv, om.brushLayer).r);
                if (om.inverted > 0.5) ow = 1.0 - ow;
            } else {
                ow = params.maskOverlayMode == 1u
                    ? analyticMaskCoverage(om, uv, params.sourceSize)
                    : maskWeight(om, uv, params.sourceSize);
            }
            if (params.maskOverlayMode == 1u) {
                rgb = half3(clamp(ow, 0.0, 1.0));
            } else if (om.activeFlags == 0u) {
                rgb = mix(rgb, half3(0.9h, 0.1h, 0.1h), half(ow * params.maskOverlayOpacity));
            }
        }
    }

    destination.write(half4(rgb, color.a), gid);
}

// ============================================================
// Brush-mask rasterization (Phase 2)
//
// A freeform paint mask is stored as a list of strokes, each a list of dabs — soft circular
// stamps in normalized UV. `stampBrush` rasterizes ONE dab into a slice of a per-brush-mask
// alpha texture array (R16Float), bounded to that dab's bounding box so the cost is the dab
// footprint, not the whole texture (the same incremental-write shape as the LUT's
// `replace(region:)` — cheap, not a full rebuild per dab). Dabs accumulate via a `max()`
// blend for additive strokes; erase strokes subtract. The array is populated two ways on the
// CPU: a full rebuild from the stroke list (image load / undo / resolution change) and live
// per-drag stamping while painting. The compositing kernel (Phase 3) samples this alpha in
// place of the analytic ellipse SDF — until then nothing reads it, so this is inert
// infrastructure verifiable in isolation against a hardcoded stroke list.
//
// Dispatches share one serial compute encoder so each dab sees the prior dab's writes
// (read_write accumulation is only race-free under serial dispatch).
// ============================================================

struct BrushDabParams {
    float2 center;    // dab center, normalized UV [0,1] in the alpha texture's frame
    float  radiusPx;  // nominal/50%-coverage radius in alpha-texture pixels
    float  hardness;  // 0-1 (ACR CenterWeight): fraction of the nominal radius at full coverage
    float  flow;      // 0-1: this dab's opacity contribution
    float  density;   // 0-1: accumulated-opacity ceiling for the owning stroke
    uint   erase;     // 0 = add (max blend), 1 = subtract
    uint   layer;     // target array slice (which brush mask)
    uint2  originPx;  // bounding-box top-left in alpha-texture pixels (grid origin)
};

/// Clears every slice of the brush alpha array to 0 before a full rebuild.
kernel void clearBrushAlpha(
    texture2d_array<half, access::write> alpha [[texture(0)]],
    uint3 gid [[thread_position_in_grid]])
{
    if (gid.x >= alpha.get_width() || gid.y >= alpha.get_height() || gid.z >= alpha.get_array_size()) {
        return;
    }
    alpha.write(half4(0.0h), uint2(gid.x, gid.y), gid.z);
}

/// Scales a compact persisted AI matte into its full-resolution shared alpha-array slice.
/// `rotationSteps` is the clockwise display-orientation delta since the matte was authored;
/// sampling applies the inverse mapping from destination UV back into the stored PNG.
struct RasterMaskBlitParams {
    uint layer;
    uint rotationSteps;
};

kernel void blitRasterMask(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d_array<half, access::write> alpha [[texture(1)]],
    constant RasterMaskBlitParams &p [[buffer(0)]],
    uint2 px [[thread_position_in_grid]])
{
    uint width = alpha.get_width();
    uint height = alpha.get_height();
    if (px.x >= width || px.y >= height || p.layer >= alpha.get_array_size()) return;

    float2 uv = (float2(px) + 0.5) / float2(width, height);
    float2 sourceUV;
    switch (p.rotationSteps & 3u) {
        case 1u: sourceUV = float2(uv.y, 1.0 - uv.x); break; // stored → display 90° CW
        case 2u: sourceUV = 1.0 - uv; break;
        case 3u: sourceUV = float2(1.0 - uv.y, uv.x); break; // stored → display 90° CCW
        default: sourceUV = uv; break;
    }
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    half coverage = half(clamp(source.sample(linearSampler, sourceUV).r, 0.0, 1.0));
    alpha.write(half4(coverage, 0.0h, 0.0h, 0.0h), px, p.layer);
}

/// Zeros slice 0 of a scratch array over a bounding box (grid origin = originPx). Used to reset
/// the per-stroke envelope scratch before each stroke's dabs are stamped into it.
kernel void clearBrushRegion(
    texture2d_array<half, access::write> tex [[texture(0)]],
    constant uint2 &originPx [[buffer(0)]],
    uint2 lid [[thread_position_in_grid]])
{
    uint2 px = originPx + lid;
    if (px.x >= tex.get_width() || px.y >= tex.get_height()) return;
    tex.write(half4(0.0h), px, 0);
}

/// Composites one stroke's coverage envelope (slice 0 of `env`) into `alpha`'s `layer` slice
/// over a bounding box. This is what makes SEPARATE strokes accumulate: within a stroke the dabs
/// are max-blended into `env` (a flat envelope capped at the stroke's flow), then source-over
/// composited here — so clicking the same spot twice builds up (`a + e·(1-a)`) toward full
/// opacity instead of clamping at one stroke's flow. Erase strokes multiply the mask down
/// (`a·(1-e)`), the symmetric inverse. Pixels the stroke didn't touch (env 0) are left unchanged.
struct BrushCompositeParams {
    uint  layer;      // target alpha slice
    uint  erase;      // 0 = source-over add, 1 = multiplicative erase
    uint2 originPx;   // bounding-box top-left (grid origin)
};

kernel void compositeBrushStroke(
    texture2d_array<half, access::read_write> alpha [[texture(0)]],
    texture2d_array<half, access::read> env [[texture(1)]],
    constant BrushCompositeParams &p [[buffer(0)]],
    uint2 lid [[thread_position_in_grid]])
{
    uint2 px = p.originPx + lid;
    if (px.x >= alpha.get_width() || px.y >= alpha.get_height()) return;
    half e = env.read(px, 0).r;
    if (e <= 0.0h) return;                       // stroke didn't cover this pixel
    half a = alpha.read(px, p.layer).r;
    half result = (p.erase != 0) ? (a * (1.0h - e)) : (a + e * (1.0h - a));
    alpha.write(half4(result, 0.0h, 0.0h, 0.0h), px, p.layer);
}

/// Rasterizes one brush dab into `alpha`'s `layer` slice, bounded to the dab's bounding box
/// (grid origin = `dab.originPx`, so `lid` is the offset within the box).
kernel void stampBrush(
    texture2d_array<half, access::read_write> alpha [[texture(0)]],
    constant BrushDabParams &dab [[buffer(0)]],
    uint2 lid [[thread_position_in_grid]])
{
    uint2 px = dab.originPx + lid;
    uint w = alpha.get_width();
    uint h = alpha.get_height();
    if (px.x >= w || px.y >= h) return;

    // Distance from the dab center in pixels (radius is already in pixel units, so the
    // profile stays circular regardless of the texture's aspect ratio).
    float2 centerPx = dab.center * float2(w, h);
    float dist = length((float2(px.x, px.y) + 0.5) - centerPx);
    // Brush size is the nominal 50%-coverage boundary shown by the solid cursor ring. Below 100%
    // hardness, a Gaussian begins at the full-strength inner radius and continues well past the
    // nominal circle. We only clip once it falls below 1/1024 coverage, where the boundary is no
    // longer perceptible; a hard brush retains a one-pixel antialiasing transition.
    float hardness = clamp(dab.hardness, 0.0, 1.0);
    float softnessRadius = dab.radiusPx * (1.0 - hardness);
    float falloff;
    if (softnessRadius <= 0.5) {
        falloff = 1.0 - smoothstep(dab.radiusPx - 0.5, dab.radiusPx + 0.5, dist);
    } else {
        float innerRadius = dab.radiusPx - softnessRadius;
        float outerRadius = innerRadius + 3.16227766017 * softnessRadius; // sqrt(log2(1024))
        if (dist > outerRadius) return;
        float t = max((dist - innerRadius) / softnessRadius, 0.0);
        falloff = exp2(-t * t); // 50% at the nominal cursor circle
    }

    float coverage = min(falloff * dab.flow, dab.density);
    half prev = alpha.read(px, dab.layer).r;
    half result;
    if (dab.erase != 0) {
        // Symmetric with the additive `max` below: over overlapping dabs in one stroke,
        // min(prev, 1 - coverage) collapses to min(prev, 1 - max(coverage)) — the erase
        // *envelope*, so the soft falloff is preserved instead of being subtracted repeatedly
        // (plain `prev - coverage` accumulates across the many overlapping dabs of a stroke and
        // saturates the edge to hard). Erasing to full 0 needs flow 1 (mirrors add capping at flow).
        result = min(prev, half(1.0 - coverage));
    } else {
        result = max(prev, half(coverage));
    }
    alpha.write(half4(result, 0.0h, 0.0h, 0.0h), px, dab.layer);
}
