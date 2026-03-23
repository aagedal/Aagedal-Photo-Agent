#include <metal_stdlib>
using namespace metal;

// ============================================================
// MaskOverlayParams — matches Swift MaskOverlayParams exactly
// ============================================================

struct MaskOverlayParams {
    float2 center;       // image UV [0,1]
    float2 radii;        // image UV [0,1]
    float rotation;      // radians
    float feather;       // 0-1
    float inverted;      // 0 or 1
    uint  visible;       // 0=hidden, 1=visible

    float2 scale;        // source→drawable (same as EditParams.scale)
    float2 sourceSize;   // source texture dimensions
    float2 drawableSize; // output drawable dimensions
};

// ============================================================
// Signed distance helpers
// ============================================================

/// Anti-aliased line from SDF distance. Returns alpha [0,1].
inline float lineAlpha(float dist, float lineHalfWidth, float aa) {
    return smoothstep(lineHalfWidth + aa, lineHalfWidth - aa, abs(dist));
}

/// Filled circle alpha. Returns alpha [0,1].
inline float circleAlpha(float2 pos, float2 center, float radius, float aa) {
    float d = length(pos - center);
    return smoothstep(radius + aa, radius - aa, d);
}

/// Dashed line alpha: modulates line alpha with a dash pattern.
inline float dashedLineAlpha(float dist, float lineHalfWidth, float aa, float arcPos, float dashLen) {
    float line = lineAlpha(dist, lineHalfWidth, aa);
    float dash = step(0.5, fract(arcPos / dashLen));
    return line * dash;
}

// ============================================================
// Mask Overlay Composite
// ============================================================

kernel void maskOverlay(
    texture2d<half, access::read_write> destination [[texture(0)]],
    constant MaskOverlayParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (params.visible == 0) return;
    if (gid.x >= uint(params.drawableSize.x) || gid.y >= uint(params.drawableSize.y)) return;

    // Map drawable pixel to source UV (same transform as editAdjustments)
    float2 sourceCoord = float2(gid) / params.scale;
    float2 uv = sourceCoord / params.sourceSize;

    // Anti-aliasing size in UV space (approximately 1 drawable pixel)
    float pixelSizeU = 1.0 / (params.sourceSize.x * params.scale.x);
    float pixelSizeV = 1.0 / (params.sourceSize.y * params.scale.y);
    float aa = max(pixelSizeU, pixelSizeV);

    // Transform to ellipse local space
    float cosR = cos(params.rotation);
    float sinR = sin(params.rotation);
    float2 d = uv - params.center;
    float2 local = float2(d.x * cosR + d.y * sinR, -d.x * sinR + d.y * cosR);
    float dist = length(local / params.radii);

    // Accumulate overlay alpha and color
    half4 existing = destination.read(gid);
    float overlayAlpha = 0.0;
    float3 overlayColor = float3(1.0); // white for all overlay elements

    // --- Outer ellipse outline ---
    float lineWidth = 1.5 * aa; // ~1.5 drawable pixels
    float outerAlpha = lineAlpha(dist - 1.0, lineWidth, aa);
    overlayAlpha = max(overlayAlpha, outerAlpha * 0.8);

    // --- Inner feather boundary (dashed) ---
    if (params.feather > 0.01) {
        float innerScale = max(1.0 - params.feather, 0.05);
        float innerDist = dist / innerScale;
        // Arc position for dash pattern: use angle around ellipse
        float angle = atan2(local.y / params.radii.y, local.x / params.radii.x);
        float arcPos = (angle + M_PI_F) / (2.0 * M_PI_F); // [0,1]
        float dashLen = 0.04; // dash period in normalized arc units
        float innerAlpha = dashedLineAlpha(innerDist - 1.0, lineWidth * 0.5, aa, arcPos, dashLen);
        overlayAlpha = max(overlayAlpha, innerAlpha * 0.35);
    }

    // --- Center dot ---
    float dotRadius = 3.0 * aa; // ~3 drawable pixels
    float dotAlpha = circleAlpha(uv, params.center, dotRadius, aa);
    overlayAlpha = max(overlayAlpha, dotAlpha);

    // --- Edge handles (4 positions along ellipse boundary) ---
    float handleRadius = 5.0 * aa; // ~5 drawable pixels
    float outlineRadius = handleRadius + 0.5 * aa;

    // Handle positions: top, right, bottom, left on the ellipse
    float2 handleOffsets[4] = {
        float2(0, -params.radii.y),  // top
        float2(params.radii.x, 0),   // right
        float2(0, params.radii.y),   // bottom
        float2(-params.radii.x, 0),  // left
    };

    for (int i = 0; i < 4; i++) {
        // Rotate handle offset back to image space
        float2 hLocal = handleOffsets[i];
        float2 hWorld = float2(
            hLocal.x * cosR - hLocal.y * sinR,
            hLocal.x * sinR + hLocal.y * cosR
        );
        float2 hPos = params.center + hWorld;

        // Dark outline
        float outline = circleAlpha(uv, hPos, outlineRadius, aa);
        if (outline > 0.001) {
            // Blend dark outline
            float darkAlpha = outline * 0.3;
            float3 darkColor = float3(0.0);
            float combined = max(overlayAlpha, darkAlpha);
            if (darkAlpha > overlayAlpha) {
                overlayColor = darkColor;
            }
            overlayAlpha = combined;
        }

        // White fill
        float fill = circleAlpha(uv, hPos, handleRadius, aa);
        overlayAlpha = max(overlayAlpha, fill);
        if (fill > 0.5) {
            overlayColor = float3(1.0);
        }
    }

    // Composite overlay onto existing pixel
    if (overlayAlpha > 0.001) {
        half3 result = mix(existing.rgb, half3(overlayColor), half(overlayAlpha));
        destination.write(half4(result, existing.a), gid);
    }
}
