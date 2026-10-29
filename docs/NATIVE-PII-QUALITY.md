# Actual native learned and hybrid privacy quality

The experimental native inspector is now scored on its **actual combined
learned-plus-production-pattern output**, using the same signed CLI for both
the rule baseline and native inspection. This closes a measurement gap: prior
quality tables described model output alone. It does not enable learned
protection in recording, imports, answers or export. F047 remains TODO.

[Machine-readable receipt](../benchmarks/native-hybrid-pii-quality-v1.json)
contains all six groups, all 432 operation receipts and a 16-file public artifact
inventory. Each actual native stdout is retained byte-for-byte inside a JSON
string, with its original SHA256. The public baseline retains actual exported
text; it is not a reimplementation of the production detectors.

## Results

The same 72 already-opened authored validation sources contain 48 positive values
and 24 negative examples. The 144 reserved test predictions remain unopened.
Sources are short synthetic templates, not representative OCR, ASR, multilingual
desktop material or verified training-unseen data. There are 48 values, not 432
independent quality examples.

| Threshold | Learned values fully masked | Combined values fully masked | Negative examples flagged | Combined character precision / recall |
| --- | ---: | ---: | ---: | ---: |
| Production rules alone | — | 14/48 | 0/24 | 89.01% / 36.65% |
| 0.3 | 45/48 | 45/48 | 20/24 | 71.04% / 97.96% |
| 0.5 | 42/48 | 42/48 | 8/24 | 79.73% / 79.64% |
| 0.7 | 29/48 | 33/48 | 0/24 | 93.25% / 62.56% |

CPU and fixed 128-token Core ML produce exactly the same learned and combined masks
at each threshold. A value counts only if every character is masked. Character
metrics ignore category; typed span metrics in the receipt apply to learned
detections only. Removed context also counts as over-redaction.

At 0.7, rules recover three additional secret values and one credit-card value.
At 0.3/0.5, rules add masked context without improving whole-value coverage on
this fixture. Three of four email values remain incomplete at 0.3; all four are
missed at 0.5/0.7. At 0.7, all four addresses are missed too. Zero flagged negatives out
of 24 does not establish a low real-world false-positive rate. **No operating
point is accepted for automatic production redaction.**

## Independent checks and provenance

The frozen runner uses signed product
`7e21e0f6fc8d1cbec4c6a49cf284813a6d12b912`, CLI SHA256
`45ef3df1e3bd2ea4fad804feeded7130193ce1a4e240644f8b806e12db18c418`,
and tooling source `f31b9312c479c23248a56d94636187f54ee8ed63`.
No Swift, C/C++, package or product test input changes in this work; the already
qualified signed app is reused. No new native app build or installation is
claimed. Exact asset hashes, code hashes, source identities and thresholds are
frozen before inference and checked during the run. These are experiment
receipts, not signed trust attestations.

All 432 native calls exit normally with result JSON. Independent standard-library
code converts UTF-16 offsets only at valid scalar boundaries, validates source,
model, compute and threshold identity, checks finite scores/categories and
bounded collections, reconstructs the rendered text from original source and
explicit masks, and checks redaction/media flags. It verifies that every final
mask is exactly the union of actual learned masks and the actual shipping-rule
baseline. It does not replicate a detector or infer masks from gold labels.
Full grapheme correctness remains covered by the separate native contracts.

The media check concerns the returned `suppressMedia` flag. No screenshot or
audio is captured, rewritten or admitted by history-free inspection. This is
not acceptance of production image/audio treatment.

The baseline imports/exports a fresh explicit synthetic library. Native calls
read only piped fixture text and explicit pinned local assets. No normal history,
provider credential or paid call is used. Original stdout/stderr logs and the
path-bearing plan remain in ignored local artifacts; public receipts retain
stderr sizes/hashes, including Core ML diagnostics. Timings are raw operation
observations including startup/model loading, not a latency, energy or device
placement benchmark. Repeated framework warnings are not hidden as successful
GPU-placement evidence.

## Reproduce

Offline replay validates all 16 artifact hashes, all 432 original stdout hashes,
source/mask/rendering/flag invariants, actual-rule union, exact backend mask
parity and every published metric, without weights or native inference:

```sh
python3 scripts/test-pii-quality.py
python3 scripts/test-pii-native-quality.py
python3 scripts/replay-pii-native-quality.py
```

The 14 existing scorer tests and 10 new output-contract tests pass. New cases
include surrogate splits, changed identities, invalid ranges/confidences,
overlap/order, inconsistent flags, literal redaction markers and partial versus
whole-value coverage. CI runs these tests and public replay offline.

To run fresh native observations, prepare the [pinned local assets](NATIVE-PII-SETUP.md),
generate the authored corpus and freeze the exact binary before inference:

```sh
python3 scripts/prepare-pii-eval.py --output /absolute/new/authored.json
python3 scripts/prepare-pii-native-quality.py \
  --binary /absolute/signed/oswindctl --binary-sha256 EXACT_SHA256 \
  --binary-source EXACT_40_CHARACTER_SOURCE_COMMIT \
  --corpus /absolute/new/authored.json --model-dir /absolute/pinned/model \
  --runtime-library /absolute/pinned/libonnxruntime.1.24.2.dylib \
  --output /absolute/new/frozen-plan
python3 scripts/evaluate-pii-native-quality.py \
  --plan /absolute/new/frozen-plan/plan.json \
  --corpus /absolute/new/authored.json --output /absolute/new/evaluation
```

Preparation/evaluation refuse existing output directories and changed frozen
inputs. Reference-count or CPU/Core ML mask differences are retained as an
explicit non-accepting result; no automatic retry or favorable substitution.
Keep sources, assets and binaries immutable throughout the ordered run.

Next gates are broader independently sourced quality data and a frozen policy,
production admission across every ingestion/egress path, policy/record revision
fences, conservative media treatment, then live desktop and power qualification.
Existing [window](NATIVE-PII-DOCUMENTS.md), [ownership](NATIVE-PII-RUNTIME.md) and
[setup](NATIVE-PII-SETUP.md) contracts remain separate. This result does not
establish competitor parity, ranking or release acceptance.

The [public domain validation follow-up](PII-DOMAIN-VALIDATION.md) completes 918 inspections on 153 frozen external synthetic documents. At 0.7, combined coverage is 118/250 values with 4/45 policy-negatives flagged on CPU, and 115/250 with 3/45 on Core ML. No policy is accepted. That broader result does not alter this historical 72-source result.
