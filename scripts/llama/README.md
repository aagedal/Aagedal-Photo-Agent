# Bundled llama.cpp runtime

The app includes the Apple Silicon completion helper and its required dynamic libraries
from the official MIT-licensed llama.cpp release **b11377**. Metal kernels are embedded
in the Metal library. No runtime installation or server configuration is needed by users.
Settings offers Borealis 4B Q4_K_M for Norwegian and Gemma 3 4B Instruct Q4_K_M
for general multilingual use. Only the chosen model is downloaded, when explicitly
requested. Both use the Gemma 3 chat format. Downloads are stored separately and
can be selected again with checksum verification and no additional network transfer.

`Vendor/llama.cpp/runtime.json` records the pinned upstream archive URL, SHA-256 and
individual artifact hashes. The upstream license is bundled beside the executable.
The runtime source is available at https://github.com/ggml-org/llama.cpp/tree/b11377.

To reconstruct the checked-in runtime on macOS:

```sh
# Remove the old Vendor/llama.cpp folder explicitly before replacing it.
python3 scripts/llama/prepare_runtime.py
```

The Xcode “Sign Bundled Binaries” phase verifies artifact hashes, copies the runtime to
`Contents/Helpers/llama.cpp`, and signs libraries followed by the executable with the
app's signing identity for release builds. It does not download anything during builds.

Inference currently launches a local, single-use completion process with the caption
in a private temporary prompt file. It never opens a listening port. Cancellation
terminates the child and discards output; the actor holds admission until the child
stops. Every request releases model memory on exit. The backend-independent request
and face-context APIs support a later sequential batch worker; persistent model reuse
can be added to that backend when batch performance is measured.

The optional MLX path remains available for existing converted model folders. The
GGUF installers never download or locally converts full-precision weights.
