These synthetic 64×48, one-second solid-colour clips exercise native timecode reading and exact frame extraction. They contain no real footage or audio.

Generated with the app's bundled FFmpeg:

```sh
ffmpeg -f lavfi -i 'color=c=red:s=64x48:r=25:d=1' -c:v libx264 -timecode '01:00:00:00' source-timecode.mov
ffmpeg -f lavfi -i 'color=c=blue:s=64x48:r=30000/1001:d=1' -c:v libx264 relative-timecode.mp4
ffmpeg -f lavfi -i 'color=c=green:s=64x48:r=30000/1001:d=1' -c:v libx264 -timecode '01:00:00;00' drop-frame-timecode.mov
```

`high-bit-depth.mov` is a five-frame, 10-bit ProRes gradient used to check lossless 16-bit RGB export:

```sh
ffmpeg -f lavfi -i 'nullsrc=s=64x48:r=25:d=0.2,format=yuv422p10le,geq=lum=64+X*14:cb=512:cr=512' -c:v prores_ks -profile:v 3 -timecode '01:00:00:00' high-bit-depth.mov
```
