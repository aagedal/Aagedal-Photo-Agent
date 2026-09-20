# Downloadable Whisper model provenance

The in-app model catalog uses multilingual, unquantized GGML weights from
[`ggerganov/whisper.cpp`](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1),
pinned to commit `5359861c739e955e79d9a303bcbc70fb988958b1`.

Public revision and LFS metadata were checked with the Hugging Face CLI on 2026-09-21:

```sh
hf models info ggerganov/whisper.cpp --expand sha --format json
hf models list ggerganov/whisper.cpp --revision 5359861c739e955e79d9a303bcbc70fb988958b1 --format json
```

| File | Exact bytes | LFS SHA-256 |
| --- | ---: | --- |
| ggml-tiny.bin | 77691713 | be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21 |
| ggml-base.bin | 147951465 | 60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe |
| ggml-small.bin | 487601967 | 1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b |

Downloads are an explicit Settings action. Only model weights are requested; no
voice memo, transcript, or image is uploaded. Hugging Face and its HTTPS storage
redirects receive normal connection metadata. The ephemeral download session does
not use the shared cookie or credential stores. There is no automatic model update.

The service streams to a temporary file, enforces expected byte count, verifies
SHA-256 in bounded chunks, and atomically publishes into private Application
Support storage. Interrupted and invalid downloads are removed. Existing model
files are verified before reuse. Files are data only, never executed. Checksums
establish identity with the pinned upstream artifact; they are not an independent
security audit or a substitute for product licensing review.

Validation on 2026-09-21: the production download service fetched Tiny through
Hugging Face's HTTPS redirects and verified all 77,691,713 bytes against the pinned
SHA-256. A second installed-model lookup rehashed and accepted the resulting file.
The isolated Swift 6 service test suite passed 9 tests (11 parameterized cases),
covering reuse, permissions, size/hash failures, preserved existing files,
cancellation cleanup, mutation, symlinks/hardlinks, concurrent operations, and path
traversal. Base and Small were checked against upstream metadata, not downloaded
in this smoke run.
