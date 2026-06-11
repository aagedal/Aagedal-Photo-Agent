# TODO

## Priority
[] Rebuild bundled ffmpeg without `--enable-nonfree` / `--enable-libfdk-aac` before release — the current binary's `-version` output shows `--enable-nonfree`, which makes it legally non-redistributable (fdk-aac is GPL-incompatible). The app only uses ffmpeg for AVIF/JPEG XL encoding, so dropping the audio encoders loses nothing. A plain `--enable-gpl --enable-version3` build is redistributable under GPL-3.0, matching the app license.


## Nice to have
[] Reduce time for hover help text
[x] Fix iCloud sync regressions — container now visible in iCloud Drive (added NSUbiquitousContainers to Info.plist); container I/O routed through NSFileCoordinator (new CloudCoordinatedIO) so Templates/Lists folders no longer fork into "Templates 2"/"Lists 2" conflict duplicates that stranded files; .icloud placeholders are now downloaded + de-mangled on read
[x] Make it possible to use variables in Keywords (Use case: I want my initials and todays date to be part of a single keyword) — keywords & Person Shown now resolve via Process Variables; added {initials} variable + Settings field
[] Make it possible to sync and export presets. JSON in iCloud?
[] Scan-mode popover UX (Face / Sports / Red Carpet / Expression) replacing the settings cog + rescan button — see docs/scan-modes-followup.md
[] Re-cluster from stored embeddings without re-embedding (makes mode/threshold changes instant)
