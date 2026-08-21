# Editorial container fixture validation — 2026-08-21

The repository now contains a deterministic CC0 synthetic editorial corpus generated specifically
for Aagedal Photo Agent: 16×12 TIFF, PNG, and JPEG XL gradients plus a standards-shaped RAW XMP
sidecar with fictional descriptive, Camera Raw, and foreign properties. A checked-in manifest binds
the reviewed bytes by SHA-256, and the generator documents ImageIO and bundled FFmpeg/libjxl
provenance.

Production metadata writes and read-back succeed for TIFF, PNG, and JPEG XL. TIFF and PNG retain
identical decoded pixels; JPEG XL retains its original codestream boxes. The RAW test binds the real
sidecar to an opaque camera-file sentinel, routes embedded requests to XMP, preserves Camera Raw and
unmodeled properties, and proves the source bytes never change. It does not fabricate a proprietary
camera RAW original.

The corpus exposed a real TIFF preservation false positive. TIFF serialization adds or relocates
IFD carrier/offset tags for XMP and Photoshop/IIM, and the writer adds IIM's UTF-8 declaration.
Those exact serialization shells are now excluded from unrelated-domain identity because their
payloads are verified in their own domains; changed camera Make and unmodeled IPTC datasets still
produce a mismatch.

ImageIO advertises HEIC on this host but cannot finalize a HEIC fixture in the sandbox. No HEIC
round trip is claimed; tests instead assert the typed support boundary (EXIF/XMP/Camera Raw
supported, IIM unsupported). The official IPTC reference image, a redistributable decodable HEIC,
a representative camera RAW original, and Bridge/Photo Mechanic outputs remain external inputs.

The isolated build succeeded and the combined container/preservation run passed 14 tests in two
suites with no failures. PBX lint, JSON validation, generator type-check, fixture hashes, conflict
scan, and `git diff --check` passed.
