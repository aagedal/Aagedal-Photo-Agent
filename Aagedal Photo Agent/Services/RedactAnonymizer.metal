#include <metal_stdlib>
using namespace metal;

// Redact Anonymizer layer passes, ported from the Redact Anonymizer plugin
// (github.com/aagedal/Redact-Anonymizer, shared/AnonymizerKernel.h): random spatial
// distortion → separable Gaussian blur → mosaic (with seeded cell/colour noise and
// desaturation), optionally Blur After Mosaic, and the Frosted Glass finish.
//
// Differences from the plugin, for a photo editor whose preview and export render at
// different resolutions and frames:
// - Positions (warp field, mosaic cells, grain) are evaluated in IMAGE pixels — the full
//   source frame of this render — through `texToImage`, so a cropped export (which works in
//   the crop's frame) lands on the same cells and warp as the uncropped preview.
// - Cell and colour noise are keyed by the cell's index rather than its centre pixel, so the
//   proxy preview and the full-resolution export draw the same offsets.
// - The working space is linear; the noise, frost lift and grain are applied to a
//   gamma-2.2 encoding so their strength reads like the plugin's (display-encoded hosts).
// Keep RedactPassParams in sync with `RedactPassParams` in MetalEditPipeline+Redact.swift.

struct RedactPassParams {
    int width;            // working texture size
    int height;
    int blurRadius;       // texture pixels, 0 = pass-through
    int blurDir;          // 0 = horizontal, 1 = vertical
    float blurSigma;      // texture pixels
    int mosaicShape;      // 0 square, 1 triangle, 2 hexagon
    float mosaicSize;     // image pixels, <= 1 disables the mosaic (and its noise)
    float distortAmount;  // image pixels, 0 disables
    float distortScale;   // image pixels
    uint seed;            // distortion pattern
    uint cellSeed;        // cell/colour noise and frost grain
    float biasDx;         // zero-mean correction of the displacement field
    float biasDy;
    float desaturate;     // 0..1
    float cellNoise;      // 0..1 of full range
    float colorNoise;     // 0..1 of full range
    float frostAmount;    // 0..1
    float frostGrainSize; // image pixels
    float frostR;         // frost colour, gamma-2.2 encoded (as picked)
    float frostG;
    float frostB;
    // Texture pixel → image pixel: image = A * tex + b.
    float a00; float a01; float a10; float a11;
    float b0; float b1;
    // Image-space vector → texture-space vector: inverse of A.
    float i00; float i01; float i10; float i11;
};

static inline float2 redactToImage(constant RedactPassParams& p, float2 tex)
{
    return float2(p.a00 * tex.x + p.a01 * tex.y + p.b0,
                  p.a10 * tex.x + p.a11 * tex.y + p.b1);
}

static inline float2 redactToTexVector(constant RedactPassParams& p, float2 v)
{
    return float2(p.i00 * v.x + p.i01 * v.y, p.i10 * v.x + p.i11 * v.y);
}

static inline float2 redactImageToTex(constant RedactPassParams& p, float2 image)
{
    return redactToTexVector(p, image - float2(p.b0, p.b1));
}

static inline uint redactIHash(uint x)
{
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

static inline float redactRand01(int ix, int iy, uint seed, uint channel)
{
    uint h = redactIHash(uint(ix) * 0x9E3779B1u
                         ^ uint(iy) * 0x85EBCA77u
                         ^ seed * 0xC2B2AE3Du
                         ^ channel * 0x27D4EB2Fu);
    return float(h) * (1.0f / 4294967295.0f);
}

static inline float redactSmoothT(float t)
{
    return t * t * (3.0f - 2.0f * t);
}

static inline float redactVNoise(float px, float py, uint seed, uint channel)
{
    float fx = floor(px);
    float fy = floor(py);
    int ix = int(fx);
    int iy = int(fy);
    float tx = redactSmoothT(px - fx);
    float ty = redactSmoothT(py - fy);
    float a = redactRand01(ix,     iy,     seed, channel);
    float b = redactRand01(ix + 1, iy,     seed, channel);
    float c = redactRand01(ix,     iy + 1, seed, channel);
    float d = redactRand01(ix + 1, iy + 1, seed, channel);
    float ab = a + (b - a) * tx;
    float cd = c + (d - c) * tx;
    return ab + (cd - ab) * ty;
}

// Two octaves of value noise; the finer one on a lattice rotated by atan(3/4) breaks up the
// locally near-affine look a single octave has. Mirrors AnonAlgo::Displacement and the Swift
// `RedactDisplacement.field` used for the bias.
static inline float2 redactDisplacement(float2 q, float invScale, uint seed)
{
    float px = q.x * invScale;
    float py = q.y * invScale;
    float qx = (px * 0.8f - py * 0.6f) * 2.7f;
    float qy = (px * 0.6f + py * 0.8f) * 2.7f;
    float n0 = redactVNoise(px, py, seed, 0u) * 2.0f - 1.0f;
    float n1 = redactVNoise(px, py, seed, 1u) * 2.0f - 1.0f;
    float n2 = redactVNoise(qx, qy, seed, 2u) * 2.0f - 1.0f;
    float n3 = redactVNoise(qx, qy, seed, 3u) * 2.0f - 1.0f;
    return float2((n0 + n2 * 0.5f) * 0.6666667f, (n1 + n3 * 0.5f) * 0.6666667f);
}

static inline float4 redactSampleBilinear(texture2d<half, access::sample> src, float2 texPx)
{
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 size = float2(src.get_width(), src.get_height());
    return float4(src.sample(linearSampler, (texPx + 0.5f) / size));
}

static inline float redactEncode(float v) { return sign(v) * pow(abs(v), 1.0f / 2.2f); }
static inline float redactDecode(float v) { return sign(v) * pow(abs(v), 2.2f); }

// ---- Layer 1: random spatial distortion ----

kernel void redactDistort(
    texture2d<half, access::sample> src [[texture(0)]],
    texture2d<half, access::write> dst [[texture(1)]],
    constant RedactPassParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.width) || gid.y >= uint(p.height)) return;
    float2 tex = float2(gid);
    float4 c;
    if (p.distortAmount <= 0.001f) {
        c = float4(src.read(gid));
    } else {
        float invScale = 1.0f / max(p.distortScale, 2.0f);
        float2 n = redactDisplacement(redactToImage(p, tex), invScale, p.seed);
        float2 displacement = (n - float2(p.biasDx, p.biasDy)) * p.distortAmount;
        c = redactSampleBilinear(src, tex + redactToTexVector(p, displacement));
    }
    c.a = 1.0f;
    dst.write(half4(c), gid);
}

// ---- Layer 2: separable Gaussian blur (also the Frosted Glass blur) ----

kernel void redactBlur(
    texture2d<half, access::read> src [[texture(0)]],
    texture2d<half, access::write> dst [[texture(1)]],
    constant RedactPassParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.width) || gid.y >= uint(p.height)) return;
    int r = p.blurRadius;
    if (r < 1) {
        dst.write(src.read(gid), gid);
        return;
    }
    int x = int(gid.x);
    int y = int(gid.y);
    float twoSigmaSq = 2.0f * p.blurSigma * p.blurSigma;
    float4 acc = float4(0.0f);
    float sum = 0.0f;
    for (int i = -r; i <= r; ++i) {
        int sx = p.blurDir == 0 ? clamp(x + i, 0, p.width - 1) : x;
        int sy = p.blurDir == 1 ? clamp(y + i, 0, p.height - 1) : y;
        float wgt = exp(-float(i * i) / twoSigmaSq);
        acc += float4(src.read(uint2(sx, sy))) * wgt;
        sum += wgt;
    }
    float4 c = acc / sum;
    c.a = 1.0f;
    dst.write(half4(c), gid);
}

// ---- Layer 3: mosaic ----

static inline float redactRoundHalfUp(float v) { return floor(v + 0.5f); }

// Cell centre in image pixels for the triangle / hexagon tilings (AnonAlgo::MosaicCellCenter).
static inline float2 redactCellCenter(float2 q, float b, int shape)
{
    if (shape == 1) {
        float fx = q.x / b;
        float fy = q.y / b;
        float ixf = floor(fx);
        float iyf = floor(fy);
        float u = fx - ixf;
        float v = fy - iyf;
        float cx, cy;
        if ((int(ixf + iyf) & 1) == 0) {
            if (u > v) { cx = 2.0f / 3.0f; cy = 1.0f / 3.0f; }
            else       { cx = 1.0f / 3.0f; cy = 2.0f / 3.0f; }
        } else {
            if (u + v < 1.0f) { cx = 1.0f / 3.0f; cy = 1.0f / 3.0f; }
            else              { cx = 2.0f / 3.0f; cy = 2.0f / 3.0f; }
        }
        return float2((ixf + cx) * b, (iyf + cy) * b);
    }
    // Pointy-top hexagons via axial coordinates + cube rounding, about b tall.
    float s = b * 0.5f;
    float xf = (0.57735027f * q.x - 0.33333333f * q.y) / s;
    float zf = (0.66666667f * q.y) / s;
    float yf = -xf - zf;
    float rx = redactRoundHalfUp(xf);
    float ry = redactRoundHalfUp(yf);
    float rz = redactRoundHalfUp(zf);
    float dx = fabs(rx - xf);
    float dy = fabs(ry - yf);
    float dz = fabs(rz - zf);
    if (dx > dy && dx > dz) rx = -ry - rz;
    else if (dy > dz) ry = -rx - rz;
    else rz = -rx - ry;
    float hy = rx + rz * 0.5f;
    return float2(s * 1.73205081f * hy, s * 1.5f * rz);
}

kernel void redactMosaic(
    texture2d<half, access::read> src [[texture(0)]],
    texture2d<half, access::write> dst [[texture(1)]],
    constant RedactPassParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.width) || gid.y >= uint(p.height)) return;
    float4 c;
    float b = p.mosaicSize;
    if (b <= 1.0f) {
        c = float4(src.read(gid));
    } else {
        float2 q = redactToImage(p, float2(gid));
        float2 center;
        int2 cellKey;
        if (p.mosaicShape == 0) {
            float2 cell = floor(q / b);
            center = cell * b + b * 0.5f;
            cellKey = int2(cell);
        } else {
            center = redactCellCenter(q, b, p.mosaicShape);
            // Triangle centres sit on thirds of the lattice, hexagon centres on halves; ×3
            // keys every centre uniquely for both.
            cellKey = int2(round(center * 3.0f / b));
        }
        float2 texCenter = redactImageToTex(p, center);
        int2 sample = clamp(int2(round(texCenter)), int2(0), int2(p.width - 1, p.height - 1));
        c = float4(src.read(uint2(sample)));
        if (p.cellNoise > 0.0f || p.colorNoise > 0.0f) {
            float offset = (redactRand01(cellKey.x, cellKey.y, p.cellSeed, 7u) * 2.0f - 1.0f)
                * p.cellNoise;
            float3 chroma = float3(
                (redactRand01(cellKey.x, cellKey.y, p.cellSeed, 8u) * 2.0f - 1.0f),
                (redactRand01(cellKey.x, cellKey.y, p.cellSeed, 9u) * 2.0f - 1.0f),
                (redactRand01(cellKey.x, cellKey.y, p.cellSeed, 10u) * 2.0f - 1.0f)
            ) * p.colorNoise;
            chroma -= dot(chroma, float3(0.2126f, 0.7152f, 0.0722f));
            float3 encoded = float3(redactEncode(c.r), redactEncode(c.g), redactEncode(c.b));
            encoded = max(encoded + offset + chroma, 0.0f);
            c.rgb = float3(redactDecode(encoded.r), redactDecode(encoded.g), redactDecode(encoded.b));
        }
    }
    if (p.desaturate > 0.0f) {
        float luma = dot(c.rgb, float3(0.2126f, 0.7152f, 0.0722f));
        c.rgb = mix(c.rgb, float3(luma), min(p.desaturate, 1.0f));
    }
    c.a = 1.0f;
    dst.write(half4(c), gid);
}

// ---- Frosted Glass finish (after the frost blur) ----

kernel void redactFrost(
    texture2d<half, access::read> src [[texture(0)]],
    texture2d<half, access::write> dst [[texture(1)]],
    constant RedactPassParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.width) || gid.y >= uint(p.height)) return;
    float4 c = float4(src.read(gid));
    float2 q = redactToImage(p, float2(gid));
    int2 grainCell = int2(floor(q / max(p.frostGrainSize, 1.0f)));
    float grain = (redactRand01(grainCell.x, grainCell.y, p.cellSeed, 12u) * 2.0f - 1.0f)
        * (0.015f + 0.03f * p.frostAmount);
    float3 target = float3(p.frostR, p.frostG, p.frostB);
    float3 encoded = float3(redactEncode(c.r), redactEncode(c.g), redactEncode(c.b));
    encoded = max(encoded + (target - encoded) * p.frostAmount + grain, 0.0f);
    c.rgb = float3(redactDecode(encoded.r), redactDecode(encoded.g), redactDecode(encoded.b));
    c.a = 1.0f;
    dst.write(half4(c), gid);
}
