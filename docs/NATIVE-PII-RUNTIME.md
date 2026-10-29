# Explicit local PII inspection

OSwind now has an experimental native inspection API and a history-free CLI
command. They use the pinned GLiNER tokenizer, original-source decoder and
ONNX Runtime C API, with CPU or a fixed128-token Core ML graph. They do not
select a learned privacy policy for recording, ingestion, retrieval or export.
F047 and production privacy acceptance remain open.

```sh
printf '%s' 'Owned synthetic note: password=fixtureSecret' | oswindctl pii inspect \
  --model-dir /absolute/local/pinned-model \
  --runtime-library /absolute/local/libonnxruntime.1.24.2.dylib \
  --compute cpu --threshold 0.5 --stdin
```

Use `coreML` explicitly for the fixed bucket. CPU accepts up to512 framed
tokens; Core ML accepts up to128, including the fixed12-label prompt. Both
refuse overflow. Neither truncates, downloads assets or contacts a provider.
Input is strict UTF-8 through a pipe, at most16KiB /4096 Unicode scalars and
512 original words. A threshold strictly between zero and one is required;
0.5 is an example, **not an accepted privacy operating point**.

The model directory contains `tokenizer.json`, `tokenizer_config.json` and
`onnx/model.onnx` for CPU or `onnx/model-bucket128.onnx` for Core ML. Original
asset provenance is in [the pinned source manifest](../models/gliner-pii-edge-source.json).
The Core ML graph SHA256 is
`a6a66d8a988b9507b6d8d714a727ca47fcacef6b5090825f79b86be917e3e136`
(181078847 bytes), derived by fixing all three token-input shapes to1×128;
operators and initializers are unchanged. The explicit runtime is the previously
evaluated macOS arm64 ONNX Runtime1.24.2 dylib (27651368 bytes, SHA256
`94e1e79a7eae49dd6dec88c2ada0bf30ed2f04f02dd03abc12d7d8ebed92cdfa`).
There is no application model installer for this experimental backend yet.

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
at most32 queued requests. Queued cancellation removes work. In-flight
cancellation joins native work before discarding its result and closing the
session. Terminal `shutdown()` rejects new work, cancels queued work and waits
for all in-flight load/inference resources to close, including stale load
candidates. Cancelling the shutdown caller cannot bypass that barrier. The
shared retention policies support after-use, two/ten idle minutes and until
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

The first development runs pass12 ownership cases, followed by93 selected
tests with two unrelated opt-in skips. Both actual native backends pass the
same72 authored validation sources at0.3/0.5/0.7 (432 comparisons total).
The first development CLI run passes25 success/refusal checks. Final frozen
source qualification and packaging results will be recorded separately.

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
Long-source windows, installer/setup, application integration, policy/record
revision fences, image treatment and representative hybrid quality remain TODO.
