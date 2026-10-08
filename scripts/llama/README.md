# Bundled llama.cpp runtime

The app includes the Apple Silicon completion helper and its required dynamic libraries
from the official MIT-licensed llama.cpp release **b11377**. Metal kernels are embedded
in the Metal library. No runtime installation or server configuration is needed by users.
Settings recommends Gemma 4 12B Q4_K_M for multilingual writing. It also offers
Gemma 4 E4B, Qwen3.5 9B, Ministral 3 14B Instruct, and Gemma 4 26B A4B.
The 26B option downloads approximately 17 GB of weights and recommends at least
32 GB total Mac RAM. The catalog displays actual download sizes and memory guidance;
recommendations include headroom for macOS and the app and are not measured minimums.
Borealis and Gemma 3 are no longer offered for download. Existing selected files
remain usable when they contain a compatible chat template.
Only the chosen model is downloaded, when explicitly requested. Downloads use pinned
Q4_K_M files, revisions, sizes and SHA-256 checksums. They are stored separately and
can be selected again with checksum verification and no additional network transfer.
Each GGUF supplies its own embedded Jinja chat template. Bounded metadata reading
extracts that template, explicitly disables thinking, and launches a single
noninteractive conversation turn. Caption output requires the runtime's actual
end-of-generation marker; reasoning blocks and model-specific end tokens are removed.

`Vendor/llama.cpp/runtime.json` records the pinned upstream archive URL, SHA-256 and
individual artifact hashes. The upstream license is bundled beside the executable.
The runtime source is available at https://github.com/ggml-org/llama.cpp/tree/b11377.

To reconstruct the checked-in runtime on macOS:

```sh
# Remove the old Vendor/llama.cpp folder explicitly before replacing it.
python3 scripts/llama/prepare_runtime.py
```

The Xcode “Sign Bundled Binaries” phase verifies artifact hashes, copies the runtime to
`Contents/Resources/llama-runtime` (alongside its manifest and license),
removes the obsolete generated `Contents/Helpers/llama.cpp` and
`Contents/Helpers/llama-runtime` folders on incremental builds, and signs libraries followed by the executable with the
app's signing identity for release builds. It does not download anything during builds.

Inference currently launches a local, single-use completion process with the caption
in a private temporary prompt file. It never opens a listening port. Cancellation
terminates the child and discards output; the actor holds admission until the child
stops. Every request releases model memory on exit. The backend-independent request
and face-context APIs support a later sequential batch worker; persistent model reuse
can be added to that backend when batch performance is measured.

The optional MLX path remains available for existing converted model folders. The
GGUF installers never download or locally convert full-precision weights.
