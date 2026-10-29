# Native setup for experimental PII inspection

The Models settings panel can prepare the local inspection models with progress,
cancellation, failure/retry and a prepared-cache location. The same preparation
is available through the history-free CLI:

```sh
oswindctl pii prepare
oswindctl pii verify
printf '%s' 'Owned example: password=fixtureSecret' |
  oswindctl pii inspect --compute coreML --threshold 0.5 --stdin
```

All three commands accept `--cache-root /absolute/cache`. Inspection also
accepts the earlier explicit `--model-dir` / `--runtime-library` pair; choose
either that pair or the prepared cache. Verification and inspection never
download missing assets. `--data` and `--vault` are refused before resolving a
library. Apple Silicon macOS14+ is required for this pinned runtime.

This prepares **manual text inspection**. It does not select a learned capture,
import, answer or export policy. The example0.5 threshold is not an accepted
privacy operating point; the detector can miss PII or remove ordinary text.
F047 remains TODO. [Runtime contract](NATIVE-PII-RUNTIME.md) and
[existing quality findings](PII-EVALUATION.md) remain applicable.

## Assets and derivation

The compiled [recipe](../models/pii-native-setup.json) pins eight public
downloads totaling201963274 bytes. The installed payload is393488824 bytes
plus its small preparation receipt. Allow1 GB of free space for scratch work.
The default cache is `~/Library/Caches/OSwind/models/pii`; each complete recipe
gets its own content-derived directory name. Neither model weights nor the
runtime binary is bundled in the application.

The original GLiNER graph/tokenizer/card/config are pinned at model revision
`9b7f39b0a2da971a5beea78d35f1539d4009c891`. The pinned Ettin model card declares
MIT; its associated upstream code MIT notice is retained at code revision
`6cbf954a2ecaa7c753be6468a1bccdef401d5f93`. The GLiNER model card declares
Apache2.0; its card, a full Apache2.0 license and attribution are retained.

The runtime source is the official
[ONNX Runtime1.24.2 macOS arm64 wheel](https://pypi.org/project/onnxruntime/1.24.2/),
SHA256 `d8a50b422d45c0144864c0977d04ad4fa50a8a48e5153056ab1f7d06ea9fc3e2`.
The version is deliberately pinned to the validated artifact. Native macOS
`unzip`, through the existing parent-death/cancellation guardian, extracts
only the dylib and MIT license into private scratch. No Python installation,
Python import, package resolver or wheel-provided code is executed. Both
retained members receive independent byte-size/hash checks before publication.

The fixed Core ML graph is derived natively by streaming six exact metadata
patches: one GraphProto message length, its four input ValueInfo messages and
the output ValueInfo message. All other source bytes are copied unchanged.
The original bytes are hashed again on the same read descriptor during the
transformation, and the result must exactly match the independently generated
ONNX graph hash `a6a66d8a988b9507b6d8d714a727ca47fcacef6b5090825f79b86be917e3e136`.
This is a fixed recipe, not a general-purpose ONNX converter.

## Publication and cancellation

An exclusive owner-checked cache lock prevents two preparers from publishing
into the same cache. Download sizes/hashes, descriptor-bound paths, root
identity and the complete installed file recipe are verified. Caches inside
history, backup or installed model packages are refused. Corrupt existing
installations fail verification and are preserved; setup never downloads over
them. Model-cache repairs or removal remain an explicit user operation.

The runtime archive is an owned, checksum-verified private file, sealed
read-only during extraction. The guardian retains cache/workspace reservations;
the extraction child inherits stdio only and opens that owned archive path.
Archive pathname replacement is checked after extraction. This does not claim
protection from a malicious process running as the same macOS user.

Before publication, two built-in authored texts must match their independent
reference masks and labels through both CPU and Core ML. Each model owner is
shut down before preparation continues. These four compatibility checks are
not representative PII acceptance or physical GPU-placement evidence. Existing
Core ML framework diagnostics remain visible on stderr.

Only a verified13-file payload/receipt is atomically published. Cancellation
joins an active descriptor writer, child extraction or native inference before
unpublished work is cleaned. A cancellation racing after publication can leave
a complete verified installation; retry detects and verifies it. Abrupt parent
death releases reservations, with abandoned scratch cleanup on the next setup.
The ordinary cancellation and abrupt-death cases must be qualified separately.

`pii verify` checks pinned files and the preparation receipt, without executing
inference. Its receipt records the OS used when compatibility was originally
checked; verification is not a new hardware qualification on another Mac.
Reuse also verifies the full known payload and does not redownload or rerun
the probes. The CLI keeps framework diagnostics off its JSON stream.

## Development evidence and final qualification

A fresh development run downloaded all eight public files, reproduced the
Core ML graph and passed the four CPU/Core ML sample checks. That first run
used full-wheel extraction into scratch; the final implementation selects only
the two required members. Sixteen focused setup/UI cases pass with explicit
local-model/render opt-ins. Eighteen actual CLI checks include ready reuse,
both managed inspection modes, corrupt-install refusal and cancellation of an
observed live download: exit130, no result JSON and no unpublished workspace.

The first Swift build's throwing-operator error is retained, then corrected.
The first ImageRenderer-based UI test passed while producing blank Forms;
visual inspection caught this. The test now uses an owned offscreen native
hosting view and rejects a blank result. Idle/ready/failure/busy/stopping states
are checked in light and dark appearances. These renders and injected actions
do not establish native button-click or production GUI acceptance.

Final frozen-source tests, separate signed packaging, an actual fresh download
with the selective extractor, process checks and final renders are recorded
separately after completion. No energy, competitor or complete-v0 claim follows
from this setup feature.
