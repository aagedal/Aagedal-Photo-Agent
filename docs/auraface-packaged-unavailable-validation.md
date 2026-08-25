# AuraFace packaged-unavailable disclosure validation — 2026-08-25

The optional AuraFace model now has an explicit compiled product state. `CoreMLFaceEmbedder` resolves the
packaged `AuraFaceR100.mlmodelc` resource once and exposes either `available` or `unavailable`. When it is
absent, the face bar persistently shows **Unavailable** with explanatory help and accessibility copy.
`FaceRecognitionViewModel` also refuses a scan at its entry boundary before full-rescan deletion, task
creation, image work, or face-data mutation, so an omitted model cannot degrade into ordinary per-image
failures.

The release checklist requires operators to inspect the app being shipped for
`Contents/Resources/AuraFaceR100.mlmodelc`. Intentionally model-free builds must put the exact unavailable
sentence in `CHANGELOG.md`'s `### Highlights`, which Sparkle publishes as release notes. Builds advertised
with face recognition must include the compiled resource and pass manifest verification.

Focused tests construct an embedder with no model URL and verify its explicit state, user-facing copy,
release-note sentence, and typed `modelNotFound` error. A view-model boundary test verifies an unavailable
package cannot start a scan and publishes the same explanatory state. The arm64 test target compiles the
user-visible face-bar state.
