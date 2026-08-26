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
Ran 5 tests — OK

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

The app still cannot truthfully enable on-demand installation until release ownership supplies and reviews:

1. the final immutable `aagedal.me` upload location and production upload itself;
2. a trust anchor for the descriptor (for example, a pinned signing public key or a descriptor hash shipped
   with the app), plus the corresponding offline signing procedure;
3. the app-side background downloader, archive extraction, Core ML compilation/preparation, atomic install,
   retained rollback, removal UI, and relaunch-safe state persistence;
4. a migration policy proving that existing embeddings remain intact until both the new model and rollback
   model are verified;
5. clean-install, offline, interrupted/corrupt download, update, rollback, removal, and supported-macOS-tier
   tests against the real production server.

Those items require product integration, a production trust decision, or external server state. This local
packaging work does not claim that the TODO on-demand component or its exit gate is complete.
