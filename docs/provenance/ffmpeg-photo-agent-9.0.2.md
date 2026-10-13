# Bundled FFmpeg 9.0.2 Photo Agent variant

Photo Agent's development bundle uses the user-supplied `photo-agent` FFmpeg 9.0.2
artifact from `/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-8b3606d8`.
The current source resource is the subsequently supplied Developer ID signed delivery.
The shared `full` variant and the other application's video-to-SRT binary were not
replaced by this integration. The previous 9.0.1 record remains historical evidence
in [ffmpeg-whisper-bundled.md](ffmpeg-whisper-bundled.md) and its JSON companion.

## Artifact and source identity

- Supplied archive: `dist/9.0.2/ffmpeg-9.0.2-photo-agent-signed.zip`;
  extracted member `photo-agent/ffmpeg`.
- Bundled destination: `Aagedal Photo Agent/Resources/ffmpeg`.
- SHA-256: `95cdaad232586ff7cbc1f398f7544a44b58f6a8f52929211a6bacab09be5497e`.
- Size: 60,144,496 bytes. Identity refers to the frozen imported bundle; the
  external build output path can be rebuilt concurrently.
- Architecture: arm64; Developer ID Application: Truls Aagedal (3R5QGG9DW6),
  hardened runtime and secure timestamp. Local strict signature and notarized-code
  requirement checks pass. App builds re-sign the copied helper and regenerate
  its runtime descriptor; this helper ticket does not notarize the containing app.
- Initial pre-signing artifact: 60,477,800 bytes, SHA-256
  `4020b2049584b45e9bda4767ed4fd26cc0dd276dca0bcbac7c069beb97b3cfd1`.
  Mach-O header, non-signing load commands and code/data/linkage payloads match
  the signed delivery after excluding signature allocation and zero padding.
- Recipe deployment target: macOS 11.0. This is build metadata, not validation on
  every supported macOS release or a separate framework compatibility matrix.
- Original archive: `sources/ffmpeg-9.0.2.tar.xz`, SHA-256
  `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`.
  This identifies the supplied original snapshot; it is **not** a complete modified
  corresponding-source companion and was not independently fetched in this task.
- Builder checkout HEAD: `f30ebf3a77ba0539265afbf08f2af47f559177bb`, with uncommitted
  recipe changes and new patch/qualification files. The retained recipe content
  hashes identify those exact files instead of attributing them solely to HEAD.

The original archive, binary, and both corrected filter members were hashed locally.
The Whisper patch is byte-identical to Photo Agent's existing pinned correction.

## Signed delivery

Delivery ZIP SHA-256:
`064f07a7a0b5f775e1333c9e3827bc55726a875dff624d9a9e3707eb8739b54d`.
The retained [signed qualification](ffmpeg-photo-agent-9.0.2-signed-qualification.json)
and [notarization log](ffmpeg-photo-agent-9.0.2-notarization.json) identify submission
`29ebb580-93bf-40a2-a419-eaba2dfae891` as Accepted, with no issues. Its submitted ZIP
hash is `10ee9b931e892896bf21b8b115e0cde9cd6397a93348364e13f7f2a7b4500a10`,
which differs from the later delivery ZIP. The extracted helper's CDHash
`406bc36b0f170c7910de95032cba1cdfe5763495` matches the ticket and independently
passes the local notarized-code requirement. No claim is made that the two ZIPs
are byte-identical or that the app's re-signed copy shares that ticket identity.

| Modification | Patch SHA-256 | Corrected source SHA-256 |
| --- | --- | --- |
| Canonical Whisper JSON, sample-bound timing, error propagation | `f34d798a927a417c28ad6b6836b2ed881ab758b2de61170ea8f3c9000ed9ce68` | `eba0b4645581f5fd14f841f25b83550522d67d064aaa9fd752c828fa9ba38b71` |
| YADIF VideoToolbox Metal autorelease teardown | `ef03bb929ff86d5a8fc3052065e2e120d38ff6d64df6c592c331b0ee18dce595` | `950f9acd1346a45171710c163d5f78c0673b0dcd59d57ee767b66919a07c7e37` |

The corrected members are `libavfilter/af_whisper.c` and
`libavfilter/vf_yadif_videotoolbox.m` in the isolated
`sources/ffmpeg-9.0.2-photo-agent` tree. The builder describes the YADIF correction
as proposed upstream PR 23850; this record does not independently establish its
upstream merge status. The Whisper modification also affects SRT timestamps and
failure reporting in this variant; its scope is described in
[scripts/ffmpeg/README.md](../../scripts/ffmpeg/README.md).

## Build record and dependency reuse

[Retained recipe snapshot](ffmpeg-photo-agent-9.0.2-build/) contains the supplied
`build.sh`, `config.sh`, shell component recipes, filter patches and source-checking
harness. The manifest pins its entry point
`scripts/12b-ffmpeg-photo-agent.sh` and the exact supporting file hashes. Run the
snapshot only in a separate build workspace with its source inputs and dependency
prefix available; copying these files does not produce a self-contained build kit.

The builder's [dependency reuse note](ffmpeg-photo-agent-9.0.2-build/dependency-reuse.txt)
records that the compiled prefix was copied from
`/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-118d2ca2/compiled` and its
pkg-config paths were rebased. FFmpeg was rebuilt against that prefix. The external
libraries were **not independently rebuilt** for this Photo Agent variant, and no
second clean reproduction or byte-reproducible build is claimed.

The full configure flags and builder's library descriptions are retained in the
[original variant README](ffmpeg-photo-agent-9.0.2-README.md). In addition to that
README's codec/audio libraries, configuration enables libass 0.17.5, HarfBuzz
14.6.0, FreeType 2.15.0 and FriBidi 1.0.17. Their supporting source inventory includes
libpng 1.6.59, libogg 1.3.6, Brotli 1.2.0, Highway 1.4.0 and nested library notices.
The version `x264 stable` is a moving selector; the build recipe is not a fully
pinned offline source replay. The FFmpeg recipe checks exact filter-member hashes
but does not itself admit the complete original archive hash before extraction.

## Notices and distribution boundaries

[Dependency notices](../../Aagedal%20Photo%20Agent/Resources/Licenses/License-FFmpeg-Dependencies.txt)
were regenerated from the available dependency sources under the reused prefix's
original checkout, rather than retaining the previous binary's source-version
notices. [The deterministic collector](ffmpeg-photo-agent-9.0.2-collect-notices.py)
and [67-file notice inventory](ffmpeg-photo-agent-9.0.2-notices.json) record the
selection and source-byte hashes. The collection covers 23 direct/supporting source
distributions; nested optional notices do not imply all those source components
were linked. NASM, vvdec and the separately built FLAC library are not claimed as
linked third-party FFmpeg dependencies merely because they exist in the prefix.

The executable reports GPL version 3 or later, and the configure flags contain
`--enable-gpl --enable-version3` without `--enable-nonfree`. Original license headers
remain in the retained filter source/patch material. The patch and build records
are local provenance evidence; complete modified FFmpeg and dependency source
publication, source delivery verification, containing-app release signing/notarization and the
legal distribution gate remain open. The original FFmpeg archive alone does not
satisfy those uncompleted source-delivery tasks.

## Validation evidence and limits

The supplied [qualification record](ffmpeg-photo-agent-9.0.2-qualification.json)
reports feature-list equality between variants, 46 codec smoke checks and four
YADIF hardware checks per variant, 23 real-process Whisper checks, and the pinned
source sanitizer suite. These are **builder-reported** results; local application
admission evidence is maintained in the integration release record.

Photo Agent's local review checks production process behavior and synthetic image
comparisons. Updated library versions can change encoded output; successful format
admission does not establish byte-for-byte image parity, visual HDR/color approval,
recognition accuracy, or acceptance of another app's long-video SRT workflows.
