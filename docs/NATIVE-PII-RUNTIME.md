# Explicit local PII inspection

OSwind now has an experimental native inspection API and a history-free CLI
command. They use the pinned GLiNER tokenizer, original source decoder and
ONNX Runtime C API, with CPU or a fixed 128-token Core ML graph. They do not
select a learned privacy policy for recording, ingestion, retrieval or export.
F047 and production privacy acceptance remain open.

```sh
printf '%s' 'Owned synthetic note: password=fixtureSecret' | oswindctl pii inspect \
  --model-dir /absolute/local/pinned-model \
  --runtime-library /absolute/local/libonnxruntime.1.24.2.dylib \
  --compute cpu --threshold 0.5 --stdin
```

Use `coreML` explicitly for the fixed bucket. CPU accepts up to 512 framed
tokens; Core ML accepts up to 128, including the fixed 12-label prompt. Both
refuse overflow. Neither truncates, downloads assets or contacts a provider.
Input is strict UTF-8 through a pipe, at most 16 KiB / 4096 Unicode scalars and
512 original words. A threshold strictly between zero and one is required;
0.5 is an example, **not an accepted privacy operating point**.

The model directory contains `tokenizer.json`, `tokenizer_config.json` and
`onnx/model.onnx` for CPU or `onnx/model-bucket128.onnx` for Core ML. Original
asset provenance is in [the pinned source manifest](../models/gliner-pii-edge-source.json).
The Core ML graph SHA256 is
`a6a66d8a988b9507b6d8d714a727ca47fcacef6b5090825f79b86be917e3e136`
(181078847 bytes), derived by fixing all three token-input shapes to1×128;
operators and initializers are unchanged. The explicit runtime is the previously
evaluated macOS arm64 ONNX Runtime 1.24.2 dylib (27651368 bytes, SHA256
`94e1e79a7eae49dd6dec88c2ada0bf30ed2f04f02dd03abc12d7d8ebed92cdfa`).
[Native setup](NATIVE-PII-SETUP.md) now prepares these assets from Models settings or `pii prepare`; `pii verify` and managed-cache inspection never auto-download.

Only pinned byte hashes are accepted. Descriptor-bound, bounded reads reject
symlinked assets and source changes. The model is parsed from the exact verified
bytes. The runtime is copied into a unique private directory, sealed read-only,
loaded through a retained descriptor during initialization, and kept on disk
until session destruction. macOS rejects an anonymous unlinked dylib snapshot
under the current system policy; a named private snapshot succeeds. No system
policy is changed. The snapshot holds runtime code only, never input text.
Abrupt termination can leave that code snapshot in the OS temporary directory;
normal teardown removes it. This does not claim protection from malicious
same-user processes or qualify hardened/notarized distribution.

The C boundary owns its environment/session/tensors and rejects unexpected
runtime versions, input framing, shapes, nonfinite outputs or incomplete
results. CPU uses four intra-op threads and one inter-op thread. Core ML asks
for MLProgram / CPUAndGPU with CPU operators allowed. Partition compatibility
and the requested policy do not establish physical GPU placement or energy
efficiency. Vendored headers and MIT license are checked offline by
`python3 scripts/check-pii-runtime-vendor.py`; no dylib or weights are bundled.

`PIIInspector` serializes load, prediction and unload within one owner, with
at most 32 queued requests. Queued cancellation removes work. In-flight
cancellation joins native work before discarding its result and closing the
session. Terminal `shutdown()` rejects new work, cancels queued work and waits
for all in-flight load/inference resources to close, including stale load
candidates. Cancelling the shutdown caller cannot bypass that barrier. The
shared retention policies support after-use, two or ten idle minutes and until
quit; `modelResident` describes owner state, not measured physical memory.
Separate inspector instances are not a process-wide inference scheduler.

Results bind model logits to immutable source bytes and the fixed model ID.
Learned and existing secret-pattern masks are computed on the original source,
expanded to whole graphemes, merged, then applied together. A learned mask
cannot hide `password=` from the pattern detector. JSON returns the final text,
source digest, model/compute/threshold, typed original UTF-16 spans without raw
span text, learned masks, combined masks and redaction/media-suppression flags.
Any failure refuses the entire result; it does not return a regex-only fallback.
Unrecognized PII can remain in a successful result: the experimental detector
has known quality limits described in [PII-EVALUATION.md](PII-EVALUATION.md).

The CLI rejects `--data` and `--vault` before resolving a library. Core ML can
emit framework diagnostics on stdout; this dedicated process redirects FD1 to
stderr through teardown and writes only result JSON to its saved stdout.
Library callers retain control of their process output streams.

## Qualification

[PR #73](https://github.com/vibhusapra/OSwind/pull/73) and the
[qualification receipt](../benchmarks/native-pii-runtime-v1.json) distinguish
implementation source `2e95c49` from notice-packaging source `e13db2c`.
The frozen implementation passes **1,004 defined tests: 1,002 passes/two skips**,
**152 selected TSan tests**, and **48 optimized PII tests**, with zero failures.
The normal skips are physical owned system-audio opt-in and unavailable
locked/thermal visual admission. The precompiled runtime/framework internals
are outside TSan coverage.

Both actual native backends match the same 72 authored validation sources at
0.3/0.5/0.7 (432 comparisons per normal/TSan/optimized configuration).
Maximum confidence differences are 0 for CPU and 2.0862e-6 for Core ML; every
span, label and whole-grapheme model mask matches its pinned reference.
All nine ordered implementation checks pass. The final signed CLI passes 25
real-model success/refusal checks and 18 offline refusals. Its repeated current
100-image/501-query visual check preserves 459 top1 / 498 top5/top10, with
indexing, scope and reopen checks. These timings are test receipts, not paired
performance or energy measurements.

The final 34-file app/ZIP includes the MIT notice; strict signatures, normalized
raw-versus-signed payloads and complete extracted-tree equality pass. Installed
app bytes and both staged trees remain unchanged after testing. Complete
command-path inventory finds no matching owned executable; the separate image
inventory covers this run's artifact root only. No normal history or unscoped
GUI is opened by this qualification.

One **failed cross-rebuild identity assertion is retained**. After the notice
packaging rebuild, OSwind and CLI binary sections including `__text` differ
from the first package, although every Swift/C/test/vendor/package input is
unchanged; the guardian binary is identical. The cause is unproven. Same-rebuild
raw/signed payload checks pass for each package, but no cross-rebuild byte or
semantic equivalence follows from source equality. The final package receives
its own successful CLI and visual checks. The first package is superseded by
the notice-bearing package. CI source/head status is recorded separately in
the receipt and delivery ledger.

Reproduce with explicit already-present assets:

```sh
OSWIND_TEST_PII_MODEL_DIR=/absolute/pinned-model \
OSWIND_TEST_PII_RUNTIME_LIBRARY=/absolute/libonnxruntime.1.24.2.dylib \
swift test --filter 'PII.*Tests'

python3 scripts/pii-inspection-smoke.py /absolute/oswindctl \
  --model-dir /absolute/pinned-model \
  --runtime-library /absolute/libonnxruntime.1.24.2.dylib \
  --root /absolute/new-owned-fixture --real-model
```

These are compatibility and ownership checks on authored validation data.
They are not representative privacy acceptance, a reserved-test result,
capture/GUI/media acceptance, a latency/energy benchmark or competitor ranking.
Long-source windows, production application integration, policy/record
revision fences, image treatment and representative hybrid quality remain TODO.
