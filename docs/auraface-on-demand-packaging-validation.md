# AuraFace on-demand distribution packaging validation — 2026-08-26

## Result

The developer source-fetch and deterministic Core ML conversion chain was already complete; the contrary
sentence in the earlier plan-status follow-up predates the focused deterministic-build validation. This
follow-up closes another local release-engineering gap between the reviewed `.mlpackage` and a hostable
pre-converted artifact.

`scripts/package_auraface_distribution.py` now creates a deterministic stored ZIP and canonical JSON
descriptor from the manifest-verified Core ML package. The descriptor binds the archive SHA-256 and byte
count, exact package file set and hashes, model version, persisted embedding-space version, and one immutable
credential-free HTTPS artifact URL on `aagedal.me`. The command self-verifies before atomically installing
either output and refuses undeclared package files, hash or version drift, non-HTTPS/non-Aagedal URLs, URL
queries/fragments, and unreviewed replacement.

`bundled-components.json` now records `embeddingVersion: 3` and content-pins the distribution packager.
`CoreMLFaceEmbedder.version` uses `FaceRecognitionDefaults.embeddingVersion`, removing the previous local
2-versus-3 mismatch. Runtime availability copy now distinguishes not installed, downloading, ready, update
available, incompatible, verification failed, and offline states, with an approximately 125 MB/on-device/
removal/offline disclosure ready for the eventual download UI.

## Automated validation

```text
python3 -B scripts/ci/test_auraface_distribution.py
Ran 6 tests — OK

python3 -B scripts/ci/test_auraface_source_fetch.py
Ran 6 tests — OK

python3 -B scripts/ci/test_auraface_coreml_build.py
Ran 8 tests — OK

python3 -B scripts/build_auraface_coreml.py contract
AuraFace build contract verified (6 content-pinned files)

python3 -B scripts/ci/validate_bundled_components.py
validated 3 bundled component declaration(s)
```

The new packager was also exercised against the real ignored AuraFace package. It created and then
independently verified a 130,597,925-byte archive with SHA-256
`92ac01ac6aedb2cb109738108661efbfe81e0340337ba92c0269fd5065b35883`. The candidate and descriptor were
written only under `/private/tmp`; no hosted or tracked artifact was changed.

After a concurrent unrelated startup-coordinator compiler error was corrected, a fresh isolated arm64
`build-for-testing` completed successfully. `FaceEmbeddingTests` then passed with the new availability-state
coverage and the existing unavailable-build behavior intact.

## Remaining external/product blockers

The later [runtime integration](auraface-on-demand-runtime-validation-2026-08-27.md) completed the signed
descriptor trust boundary, background download, archive verification, Core ML preparation, atomic
install/rollback/removal, relaunch-safe receipts, and embedding-preserving migration policy that were still
open when this packaging record was first written. The production archive, descriptor, and signature were live
at their fixed `aagedal.me` endpoints and returned HTTP 200 on 2026-09-01. The remaining blockers are external
release work:

1. build a model-omitted release candidate and record the actual app/update size reduction; and
2. run clean-install, offline, interrupted/corrupt download, update, rollback, removal, and relaunch tests on
   every supported macOS tier against the production server, including its real TLS and cache behavior.

The local app/component separation and production-publication boundaries are complete, but the release-candidate
and real-server drill gates keep the background-download TODO and overall on-demand component exit gate open.
