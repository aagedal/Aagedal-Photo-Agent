# TODO

## Priority
[x] Rebuild bundled ffmpeg without `--enable-nonfree` / `--enable-libfdk-aac` — replaced with a minimal image-only GPL build (8.1.1, 19 MB vs 53 MB); AVIF (8/10-bit) and JPEG XL (8/16-bit) encode paths verified. Evaluated libsvtav1 for AVIF but kept libaom: SVT-AV1 4.1 rejects >33 MP at presets slower than 5 and flags 8K+ as experimental, while libaom at cpu-used 6 encodes 67 MP in ~2 s.


## Nice to have
[] Reduce time for hover help text
[x] Fix iCloud sync regressions — container now visible in iCloud Drive (added NSUbiquitousContainers to Info.plist); container I/O routed through NSFileCoordinator (new CloudCoordinatedIO) so Templates/Lists folders no longer fork into "Templates 2"/"Lists 2" conflict duplicates that stranded files; .icloud placeholders are now downloaded + de-mangled on read
[x] Make it possible to use variables in Keywords (Use case: I want my initials and todays date to be part of a single keyword) — keywords & Person Shown now resolve via Process Variables; added {initials} variable + Settings field
[] Make it possible to sync and export presets. JSON in iCloud?
[x] Face lenses (Face / Expression / Red Carpet) — see docs/scan-modes-followup.md. Phases 1–3 done: scan once, switch lens in the expanded view; Expression + Red Carpet prewarm in the background and re-cluster from stored embeddings (secondary lenses are read-only). Remaining: calibrate expression/redCarpet thresholds on real data; Phase 4 Sports as its own surface next release
[] Calibrate Expression (0.80) and Red Carpet (0.72) lens thresholds in FaceRecognitionDefaults on real labeled folders
[] Consider making Red Carpet groups nameable (identity-bearing) — currently secondary lenses are read-only
[] Re-cluster from stored embeddings without re-embedding (makes mode/threshold changes instant)
