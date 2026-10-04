# Bundled face model restoration — 2026-10-04

Baseline `f8997e5`. The user reported a recent app without its required bundled face
model. This worktree lacked the ignored local package, and Xcode explicitly excluded
`Resources/Models/AuraFaceR100.mlpackage` from app target membership. Cycle 125's
model-free build evidence was valid only for that incomplete bundle; it was not evidence
that bundled face recognition worked.

Restored the existing reviewed package from the primary checkout into this worktree
(private ignored artifact, not committed). Removed the target exclusion so Xcode
compiles the model into `Contents/Resources/AuraFaceR100.mlmodelc`. Every app build
now requires the source package and invokes the existing pinned compiled-model
validator before signing. The phase runs every time, preventing cached build outputs
from silently hiding absent model provisioning. No model download is needed by users.
Fresh developer/CI worktrees must provision the reviewed ignored package before building.

Verification on arm64 macOS 27.0.1:

- Debug app 3.0.0 build 740 builds successfully with the model.
- Bundle validator confirms 130,342,208 weight bytes and SHA-256
  `c189aaf7d6758dafb1603b4ea7f7c2161b69639434ddbce800e0cc632b26d7e0`.
- Two AuraFace channel/reference tests pass in 1.336 seconds, including actual bundled
  model compatibility: `build/qa-v3-continuation/bundled-face-tests.xcresult`.
- Executing the actual build phase against a disposable empty source root refuses
  with the required-model diagnostic before any signing or other build effects.
- Full regression: 3,831 tests / 379 suites pass in 143.527 seconds;
  `build/qa-v3-continuation/bundled-face-full.xcresult`.
- Repository validation and whitespace pass;
  `build/qa-v3-continuation/bundled-face-repository.log`. Independent review finds no blocking issue.

The rebuilt app is at
`build/qa-v3-continuation/DerivedData/Build/Products/Debug/Aagedal Photo Agent.app`.
No GUI scan or user face-data mutation was performed; broader face/hardware/privacy
release gates remain open. No user model-installation action is required for this build.
