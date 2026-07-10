# TODO

## Priority
[x] Rebuild bundled ffmpeg without `--enable-nonfree` / `--enable-libfdk-aac` — replaced with a minimal image-only GPL build (8.1.1, 19 MB vs 53 MB); AVIF (8/10-bit) and JPEG XL (8/16-bit) encode paths verified. Evaluated libsvtav1 for AVIF but kept libaom: SVT-AV1 4.1 rejects >33 MP at presets slower than 5 and flags 8K+ as experimental, while libaom at cpu-used 6 encodes 67 MP in ~2 s.

