# Learned PII developer experiment

[Results and limits](../../../docs/PII-EVALUATION.md). This does not install a model into OSwind. Use a fresh checkout to reproduce: the historical probes retain fixed ignored paths and preparation refuses existing different files. Do not replace earlier experimental receipts to reuse their names.

The corpus is authored synthetic text, not normal history. Only validation is scored. Reserved test predictions remain unopened. Model and encoder licenses are declared Apache-2.0 and MIT respectively; GLiNER is Apache-2.0, ONNX Runtime is MIT. Review upstream notices before distributing derived assets. Weights and headers are downloaded locally, not vendored here.

From repository root on Apple Silicon macOS:

```bash
uv venv --python 3.12.15 .local/pii-python-v1
uv pip sync --python .local/pii-python-v1/bin/python --require-hashes \
  benchmarks/prototypes/pii/requirements.lock

# About 500 MB of pinned public model files; packages are separate.
python3 benchmarks/prototypes/pii/prepare-assets.py \
  --download-model --download-native-headers

# No inference/download without those explicit commands; offline checks:
python3 scripts/test-pii-quality.py
python3 scripts/test-pii-assets.py

# Numeric compatibility on three already-opened validation cases.
.local/pii-python-v1/bin/python \
  .artifacts/pii-model-evaluation-v1/probe-compatibility-v3.py
.local/pii-python-v1/bin/python \
  .artifacts/pii-model-evaluation-v1/probe-mps-v1.py

.local/pii-python-v1/bin/python scripts/evaluate-pii-model.py \
  --plan .artifacts/pii-model-evaluation-v1/plan-v6.json \
  --corpus .artifacts/pii-model-evaluation-v1/authored-v1.json \
  --model .artifacts/pii-model-evaluation-v1/model \
  --runtime onnx-cpu \
  --output .artifacts/pii-model-evaluation-v1/reproduced-cpu
# Repeat with --runtime torch-mps and a new output directory.
```

Preparation without download flags reports missing assets, preserves existing matching files and refuses changed files. It stages the v6 recipe under the historical `plan-v3.json` and `plan-v5.json` names used by compatibility probes; this is a new reproduction, not the original plan hashes. Historical v1/v2 probe sources preserve the failed axis assumption and unsuccessful edit, and are not staged or recommended for inference. The compatibility/MPS probes do not enforce the full code-hash plan themselves; preparation and the full validation runner do. The dependency lock and downloaded model hashes identify the reference stack.

The actual regex baseline requires the frozen CLI hash specified in the plan. A newly built CLI is not automatically the same baseline. For another product revision, freeze a separately labeled plan/binary hash before running:

```bash
python3 scripts/evaluate-pii-baseline.py \
  --binary /absolute/path/to/frozen/oswindctl \
  --plan .artifacts/pii-model-evaluation-v1/plan-v6.json \
  --corpus .artifacts/pii-model-evaluation-v1/authored-v1.json \
  --output .artifacts/pii-model-evaluation-v1/reproduced-regex
```

The native probe needs Xcode command-line tools and the two exact checked headers. Its fixed-input export includes no source text. The dylib is loaded by explicit absolute path and must report version 1.24.2. The model, headers, binary and fixture hashes should be recorded before each experiment. Timings below enable per-node profiling and exclude tokenization/decoding; all samples are recorded, warm summaries exclude the entire first three-shape sweep.

```bash
.local/pii-python-v1/bin/python benchmarks/prototypes/pii/export-native-fixtures.py \
  --root .artifacts/pii-model-evaluation-v1 \
  --output .artifacts/pii-model-evaluation-v1/native/fixtures.bin
clang++ -std=c++17 -O2 -Wall -Wextra -Werror \
  -I .artifacts/pii-model-evaluation-v1/native/include \
  benchmarks/prototypes/pii/native-probe.cpp \
  -o .artifacts/pii-model-evaluation-v1/native/native-probe
.artifacts/pii-model-evaluation-v1/native/native-probe \
  "$PWD/.local/pii-python-v1/lib/python3.12/site-packages/onnxruntime/capi/libonnxruntime.1.24.2.dylib" \
  "$PWD/.artifacts/pii-model-evaluation-v1/model/onnx/model.onnx" \
  .artifacts/pii-model-evaluation-v1/native/fixtures.bin cpu \
  "$PWD/.artifacts/pii-model-evaluation-v1/native/reproduced-cpu-profile" 10
# With `coreml` in place of `cpu` and a fresh profile prefix, the tested
# dynamic export fails during Core ML construction. No retry is hidden.
```

Public `observations/` includes complete reference reports, synthetic CPU predictions at every threshold, actual regex masks and native results. The standard-library scorer can recompute quality from these and the generated corpus. Native input fixtures/parity report refer to previously opened validation inputs, never the reserved test. Initial assertion failures, failed Core ML attempts and earlier timings are retained separately; no favorable repeat replaces them.

## Separate static-shape diagnostic

`prepare-static-diagnostic.py` is the exact preparation behind `observations/static-plan-v1.json`. In a fresh reproduction only, make `.artifacts/pii-model-evaluation-v1/native/static-diagnostic-v1`, copy this script there as `prepare.py`, then run that copy with the locked Python. It reads only `compatibility-0-v3.npz`, fixes input/output shape metadata and preserves every operator/initializer byte. It writes a separate `static.onnx`, binary fixture and frozen plan. It is a one-shot historical preparation; do not run over existing receipts or during another probe.

Use the same compiled native executable with that graph/fixture and fresh profile prefixes under both policies. The binary header still has three slots, but **all three repeat the same single validation input**. The original native `fixedInputs:3` field counts those slots. Both policies complete thirty calls within tolerance. The Core ML profile records600 CoreML-EP partition and2,460 CPU node invocations; these are not physical GPU/ANE device assignments. Framework stdout warnings are retained in `observations/static-diagnostic-v1.json`. The original wrapper's JSON parse failed after successful execution because of that warning prelude; recovery parses exactly the terminal completed object without changing inputs or repeating inference. No dynamic-shape or three-distinct-input success is claimed by this diagnostic.

## Native decoder and fixed128 Core ML follow-up

[Native decoding report](../../../docs/NATIVE-PII-DECODING.md) distinguishes the new72-source fixed-token/dynamic-word experiment from that earlier one-input diagnostic. The original dynamic graph's failed construction remains retained. No production backend/installer selects these prototypes.

The committed `native-decoder-reference-v1.json` and `coreml-decoder-reference-v1.json` contain synthetic tensors and independent expected spans/masks. `swift test --filter PIIDecodingTests` replays all492 threshold comparisons without weights or Python. To rebuild inference observations in a fresh checkout after preparing the pinned model/runtime/header environment above:

```bash
.local/pii-python-v1/bin/python scripts/prepare-pii-decoder-eval.py \
  --model .artifacts/pii-model-evaluation-v1/model \
  --corpus .artifacts/pii-model-evaluation-v1/authored-v1.json \
  --output .artifacts/native-pii-decoding-v1/reference-v2
mkdir -p .artifacts/native-pii-decoding-v1/native
clang++ -std=c++17 -O2 -Wall -Wextra -Werror \
  -I .artifacts/pii-model-evaluation-v1/native/include \
  benchmarks/prototypes/pii/native-probe.cpp \
  -o .artifacts/native-pii-decoding-v1/native/native-probe
python3 scripts/export-pii-native-eval.py \
  --reference .artifacts/native-pii-decoding-v1/reference-v2 \
  --binary .artifacts/native-pii-decoding-v1/native/native-probe \
  --library .local/pii-python-v1/lib/python3.12/site-packages/onnxruntime/capi/libonnxruntime.1.24.2.dylib \
  --model .artifacts/pii-model-evaluation-v1/model/onnx/model.onnx \
  --output .artifacts/native-pii-decoding-v1/native-export-v2
mkdir -p .artifacts/native-pii-decoding-v1/coreml-bucket-v1
cp benchmarks/prototypes/pii/diagnose-coreml-bucket-v1.py \
  .artifacts/native-pii-decoding-v1/coreml-bucket-v1/diagnose.py
.local/pii-python-v1/bin/python \
  .artifacts/native-pii-decoding-v1/coreml-bucket-v1/diagnose.py
```

The historical bucket diagnostic is a one-shot preparation with fixed ignored paths: use a fresh directory/checkout, preserve existing receipts, and never run it during another build/test pipeline. It tests three-source CPU/Core ML smoke first and proceeds to all72 only on success. No operator or initializer is rewritten. All framework warning text and actual binary outputs remain separate from the terminal report object.

Native binary hashes and workspace paths vary across fresh builds, so provenance bytes/aggregate file hashes can differ. Preserve the committed golden fixtures; compare new tensor/decoder results under the declared tolerances and keep new receipts separate. Do not overwrite original observations to make hashes match. The public export plan has workspace-relative paths; its recorded original-plan digest identifies the original path-bearing receipt. Peak owned-process memory excludes system services. Source/model/library/policy generation ownership, device placement, long sources and application integration remain unqualified.

## Actual native combined-mask quality

[Native hybrid quality](../../../docs/NATIVE-PII-QUALITY.md) reuses signed product7e21e0f and freezes separate tooling/source/asset identities before432 real calls. The combined inspector is measured independently against actual production import/export rule masks, with no detector replication or gold-derived output. Both backends have identical masks at0.3/0.5/0.7; at0.7 the union improves whole-value coverage29/48→33/48 on the same72 authored validation sources. No operating point or production admission is accepted, and144 reserved test predictions remain unopened.

`native-hybrid-v1/` preserves all432 actual native stdout byte strings, actual exported rule text, predictions and a sanitized plan. The [receipt](../../native-hybrid-pii-quality-v1.json) binds all16 files and contains every operation/metric. Stderr byte counts/hashes are public; original repetitive framework diagnostics and machine-specific plan paths remain local.

```sh
python3 scripts/test-pii-native-quality.py
python3 scripts/replay-pii-native-quality.py
```

Replay performs no inference/download or history access. For fresh native experiments, follow the explicit prepare/evaluate recipe in the linked quality document and use new output directories. No Swift/C++ source or app binary changes in this follow-up.

## External domain validation

[Domain validation](../../../docs/PII-DOMAIN-VALIDATION.md) completes918 native inspections on153 frozen external synthetic English documents (250 values/45 policy-negatives), with both backend results retained. At0.7, combined CPU coverage is118/250 with4/45 flagged; Core ML115/250 with3/45. No privacy operating point is accepted.

`gretel-validation-v1/manifest.json` and `observations-v1/` publish hashes, labels and original-source codepoint ranges only. Source/entity/rendered text remains local after push protection flags credential-shaped synthetic source values; no bypass or credential test. The [receipt](../../pii-domain-validation-v1.json) binds ten public files and every operation.

```sh
python3 scripts/test-pii-coordinate-quality.py
python3 scripts/replay-pii-domain-quality.py
# Full literal/UTF16/rendering checks, without inference, require local inputs:
python3 scripts/replay-pii-domain-quality.py \
  --corpus /absolute/prepared/corpus.json --native-output /absolute/original/evaluation
```

Public replay proves coordinate metrics, identity, union and flag consistency; it does not reproduce literal source alignment/rendering without the explicit local files. Both modes pass on all918 stored observations. Stronger Small/Base candidates are downloaded and verified for a separate reference comparison, not installed into OSwind.

## Local reference model comparison

[Edge/Small/Base comparison](../../../docs/PII-MODEL-COMPARISON.md) completes six CPU ONNX/PyTorch MPS processes and2,754 finite-output-validated forwards on the same153-source subset. CPU/MPS masks and typed category/coordinates match for every model/threshold; no privacy operating point or installed backend is accepted. Base0.5 combined coverage207/250 with26/45 flagged illustrates the remaining trade-off.

`model-reference-v1/` preserves exact scripts, sanitized plan/source pins, all coordinate predictions, timings and process/memory observations; no raw source/entity text or weights. [Receipt](../../pii-reference-models-v1.json) binds37 files.

```sh
python3 scripts/replay-pii-reference-models.py
```

The linked document includes the explicit asset preparation and plan rehydration recipe. Use a new owned artifact root; no inference script downloads weights. No native app, retention/cancellation, power or competitor acceptance follows from reference MPS execution.
