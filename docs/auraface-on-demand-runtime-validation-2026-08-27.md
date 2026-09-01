# AuraFace verified on-demand runtime validation — 2026-08-27

## Result

The app now implements the local portion of the verified AuraFace delivery contract. It downloads only a
fixed descriptor and detached signature over HTTPS from `aagedal.me`, verifies the Ed25519 signature against
the existing Sparkle `SUPublicEDKey`, validates the descriptor's exact schema and embedding-space version,
then downloads only the immutable archive URL declared by that signed descriptor. Archive size/SHA-256 and
the exact three-file `.mlpackage` hashes are checked before extraction output can be compiled or installed.

Installation uses a private staging directory under the component root, compiles the verified `.mlpackage`,
and atomically moves complete directories. On update, `current` becomes `rollback`; an injected failure while
committing the candidate restores both the prior current and any earlier rollback. The signed descriptor and
signature are persisted with the installed source package and reverified on launch before the compiled model
is accepted. Removal deletes both current and rollback copies, while normal inference remains network-free.

Known People migration now fails closed when the current embedding model is absent or unverifiable. The
installer retriggers the existing migration only after its atomic commit; that migration already requires a
complete read-back-verified backup before resetting embeddings or advancing its version stamp. Thus a model
download, compilation, install, backup, or reset failure preserves the stored embeddings and retry state.

Settings → Face Recognition shows model state and explains the approximately 125 MB download, local-only
processing, offline behavior, and later removal before confirmation. Removal separately explains that photos
and Known People data remain and that offline matching becomes unavailable until another verified download.

The developer `.mlpackage` is now an explicit synchronized-group target exception, so it remains available to
the deterministic build and packaging tools without being compiled into ordinary app builds. The release
assistant independently rejects an exported app containing `Contents/Resources/AuraFaceR100.mlmodelc` before
notarization. This closes the local app/component separation boundary even on a release machine that has the
ignored source package present; production publishing and real-server validation remain separate gates.

## Automated validation

```text
xcodebuild build-for-testing -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/FaceEmbeddingTests" \
  -only-testing:"Aagedal Photo Agent Tests/KnownPeopleServiceTests"

** TEST BUILD SUCCEEDED **

xcodebuild test-without-building -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/FaceEmbeddingTests" \
  -only-testing:"Aagedal Photo Agent Tests/KnownPeopleServiceTests"

28 tests in 2 suites passed
** TEST EXECUTE SUCCEEDED **
```

The focused cases use generated in-memory Ed25519 keys and local fixtures; they never contact a real server.
They cover invalid signatures and HTTPS origins, clean install and persisted receipt verification, corrupt
archive/package rejection, commit failure restoration, successful retained rollback, declared-endpoint-only
download, offline removal, and deferral of embedding migration until model verification.

## Remaining external validation

- **Production publication update (2026-09-01):** all three production endpoints are live and returned HTTP 200:
  [AuraFaceR100.mlpackage.zip](https://aagedal.me/models/auraface/AuraFaceR100.mlpackage.zip) as
  `application/zip` with 130,597,925 bytes,
  [AuraFaceR100.distribution.json](https://aagedal.me/models/auraface/AuraFaceR100.distribution.json) as
  `application/json` with 779 bytes, and
  [AuraFaceR100.distribution.json.sig](https://aagedal.me/models/auraface/AuraFaceR100.distribution.json.sig) as
  `application/pgp-signature` with 89 bytes. Publication is no longer a missing prerequisite; the release-candidate
  drills below must still prove the hosted bytes satisfy the app's signature and hash contract.
- A release candidate without the bundled model must exercise clean install, offline startup, interrupted
  download, update, rollback, removal, and relaunch on each supported macOS tier against that production host.
- Hosting cache headers, content lengths, TLS behavior, and operational rollback are external server state and
  were intentionally not simulated as proof of production readiness here.
