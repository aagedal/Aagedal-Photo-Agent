# Aagedal Photo Agent 3.0 known limitations

**Status:** release-candidate draft  
**Last reviewed:** 2026-08-25

These are material product and evidence boundaries, not a list of unfinished internal tasks.

## Analysis is evidence, not a verdict

- Metadata conflicts, C2PA state, residual patterns, edges, alpha, scopes, annotations, and timeline/map
  context can support an investigation, but none establishes that an image is authentic, manipulated, or
  AI-generated.
- Compression/residual views also react to ordinary recompression, sharpening, denoising, scaling, HDR
  processing, camera pipelines, and format conversion.
- C2PA validity and signer trust are separate. C2PA signing remains an experimental preview, and carriage
  of a credential into a new rendition does not prove the credential remains valid for that rendition.
- 3.0 does not ship an AI-origin model, automatic AI-artifact highlighter, clone/copy-move detector, or
  automatic sun/shadow consistency analyzer. The Meta and Google commands are external links, not local
  analyzers or integrations.

## Source, case, and report boundaries

- Cases and reports are tied to exact source bytes. Changed or unavailable source files can leave earlier
  evidence readable, but stale evidence is not silently rebound to different bytes.
- Analysis cases, map state, notes, and named versions are app-private JSON, not interoperable IPTC/XMP.
  On a read-only photo folder the app uses a local Application Support fallback that does not travel with
  the folder.
- A `.pint` project contains working-folder source images, matching XMP sidecars, and folder-local Photo
  Agent case/metadata/version documents. The archive manifest validates the payload before import, but it
  does not make the archive encrypted or independently attest the images' origin.
- PDF reports reproduce a frozen Photo Agent snapshot and disclose methods/limitations. They are not
  signed attestations, legal conclusions, or a substitute for preserving original evidence. Users remain
  responsible for sensitive-field and map inclusion choices.

## Maps and solar position

- Apple Maps and OpenStreetMap imagery can be unavailable, stale, incomplete, differently projected, or
  limited by network/service conditions. Reports may use a schematic fallback rather than licensed map
  imagery.
- Place search and reverse geocoding are suggestions, not proof of a photo location.
- Solar directions depend on the supplied coordinate, timezone-qualified time, fixed offset, and the
  disclosed calculation model. The overlay assumes a geometric/flat local horizon and cannot account for
  terrain, buildings, cloud, camera orientation, lens projection, edited pixels, or an incorrect clock.
  It does not inspect photographic shadows.

## Comparison and rendering

- Pan/zoom synchronization aligns normalized display coordinates; it is not feature matching or automatic
  registration. Wipe is a presentation layout, while a computed difference blend is deferred.
- Very large images, two RAW files, HDR/SDR display pairing, live Develop rendering, and external-display
  changes can increase memory or render latency. Target-tier performance budgets and hands-on display/GPU
  validation remain release gates and are not claimed by this draft.
- Color, alignment, keyboard-only, VoiceOver, upgrade/downgrade, and crash-interruption automation does not
  replace the open release-candidate manual validation passes.

## Metadata and delivery interoperability

- Generated support tables describe Photo Agent's implemented read/write path. They do not claim current
  round trips through every Adobe Bridge, Photo Mechanic, HEIC/HEIF, RAW, or delivery-server combination.
- External tools can interpret metadata differently. Consult the
  [metadata support table](metadata-field-support.md) before relying on a particular carrier/write mode.
- Deadline Send supports staged SDR JPEG/TIFF and HDR Adaptive JPEG gain-map/16-bit TIFF derivatives only.
  Original-file and XMP-sidecar-only delivery are rejected.
- FTP/FTPS/SFTP protocol success and remote existence/size are non-cryptographic acknowledgements. SFTP
  supports password/netrc authentication, not SSH private keys, and a narrow local path
  time-of-check/time-of-use interval remains before `curl` opens a verified staged file.
- Sony voice-memo discovery and companion-safe ingest/rename foundations do not yet provide general
  playback, transcription, or delivery, and validation does not cover every Sony camera/firmware layout.

## Optional model availability

Face detection uses Apple Vision and face matching uses the optional packaged AuraFace CoreML model. A
build without that model reports face recognition as unavailable and must not advertise scans as working.
This is separate from the unapproved AI-origin analyzer described above.

## Privacy and legal readiness

The repository contains a [3.0 privacy draft](../PRIVACY.md) and automated privacy checks. Runtime log
capture, filesystem-interruption/network-capture review, and external legal/privacy approval remain open
release gates; this documentation does not claim those reviews have occurred.
