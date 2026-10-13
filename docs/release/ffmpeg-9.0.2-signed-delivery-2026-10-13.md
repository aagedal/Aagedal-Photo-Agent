# Signed FFmpeg 9.0.2 delivery — 2026-10-13

The supplied `dist/9.0.2/ffmpeg-9.0.2-photo-agent-signed.zip` in the builder's
`t3-8b3606d8` worktree is now the app's source artifact. Its extracted helper is
60,144,496 bytes, SHA-256
`95cdaad232586ff7cbc1f398f7544a44b58f6a8f52929211a6bacab09be5497e`.
The manifest and current provenance identify that exact signed source; notices,
recipe pins, Whisper correction and application code are unchanged.

## Signing and notarization

Strict Developer ID verification passes for Truls Aagedal, team `3R5QGG9DW6`,
hardened runtime, timestamp 2026-10-13 13:06:40 CEST. Local
`codesign --verify --strict --check-notarization -R='notarized'` passes. Helper
CDHash `406bc36b0f170c7910de95032cba1cdfe5763495` matches the retained Accepted
notarization ticket, submission `29ebb580-93bf-40a2-a419-eaba2dfae891`, no issues.

The current delivery ZIP hash is
`064f07a7a0b5f775e1333c9e3827bc55726a875dff624d9a9e3707eb8739b54d`.
The submitted ZIP hash in Apple's retained log is
`10ee9b931e892896bf21b8b115e0cde9cd6397a93348364e13f7f2a7b4500a10`.
These are distinct archives; executable ticket identity is verified independently.
This helper's notarization does not notarize the containing app or its re-signed copy.

## Verification

Evidence: ignored `build/ffmpeg-9.0.2-signed-delivery/`. Host remains arm64 macOS
27.0.1 (26A434), Xcode 27.0 (27A266a). Comparison against the original source helper
from `261b5d2` establishes matching Mach-O headers, non-signing load commands and
code/data/linkage segment payloads after excluding signature allocation/zero padding
(`code-equivalence.json`). This is a signing-only delivery of the same build.

The development app builds successfully at
`build/continuation-13/Build/Products/Debug/Aagedal Photo Agent.app`, version 3.0.0,
build 742. Its own signing step generates a new helper identity: 60,144,464 bytes,
SHA-256 `820b471e6c199a97465ec0d7b5421423675bc8f955deafeff8b4733f02851461`.
The generated runtime descriptor matches those exact bytes and the unchanged
`photo-agent-whisper-json-v1` contract. App signature verification passes.

Because the executable identity changed, all **ten production runner/provider/
parser/reader/provenance probe cases were rerun and pass** on that actual app-signed
helper (`provider-app-signed/report.json`), including CPU explicit/automatic language,
silence, timeout, cancellation, input/model/executable drift, authorization refusal
and GPU request. The supplied model/audio identities are unchanged from the preceding
integration record. GPU request success does not prove acceleration or accuracy.
Component validation, generated documentation, whitespace and independent review pass.

The preceding 4,050-pass/two-Sony-skip integrated suite remains recorded in
[the integration report](ffmpeg-9.0.2-photo-agent-integration-2026-10-13.md).
It was not repeated for unchanged application/Whisper code; this delivery has fresh
build/signature/descriptor and executable-identity probe evidence. Native provider
setup, complete corresponding source delivery, containing-app Release signing/
notarization, performance/device/color/accuracy and broader 3.0 gates remain open.

No other application's helper was replaced, and no user media/preferences were changed.
The imported helper signature is preserved in repository resources; app builds still
sign their copy with the build identity and regenerate runtime admission evidence.
