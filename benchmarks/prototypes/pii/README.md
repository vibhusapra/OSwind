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
