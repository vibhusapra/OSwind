# Public domain privacy validation

This follow-up broadens the [72-source authored fixture](NATIVE-PII-QUALITY.md)
with externally authored synthetic English documents. **All 918 native inspections completed; quality remains insufficient for an
accepted production policy.** Data admission and execution contracts pass,
while missed values and over-redaction remain substantial.

The source is [Gretel's public validation split](https://huggingface.co/datasets/gretelai/gretel-pii-masking-en-v1/tree/e06eb1499ca8d54470f085021cd8e54f9efac7fd),
revision `e06eb1499ca8d54470f085021cd8e54f9efac7fd`. Its pinned
[publisher card](https://huggingface.co/datasets/gretelai/gretel-pii-masking-en-v1/blob/e06eb1499ca8d54470f085021cd8e54f9efac7fd/README.md)
declares Apache-2.0 and describes synthetic documents generated with Gretel
Navigator/Mistral Nemo. The subset retains attribution and the license.
Model-training overlap is unknown. External authorship does not establish
training-unseen, natural desktop, OCR/ASR or multilingual acceptance.

[Source manifest, license and reader pin](../benchmarks/prototypes/pii/gretel-validation-v1/)
identify the 2,031,349-byte validation parquet, SHA256
`3de64be0dddd0dc8a6a1a1368533cc1efe8a9ec290f87feaa064e4e78a5d22b8`.
The data reader is a separately hash-pinned PyArrow 21.0.0 wheel for Python
3.12/macOS arm64. No dataset reader is added to the app or native inference.
Only validation and the publisher card were downloaded; no public test split
or old authored reserved-test predictions were opened.

## Admission and selection

All 5,000 source records pass exact schema, identity, bounded UTF-8 and literal
annotation checks. They have 5,000 unique IDs/texts, 47 domains and 42 annotation
types. The publisher supplies strings without character offsets. Each annotation
must appear **exactly once**, including overlapping occurrences; missing,
repeated, normalized or case-adjusted alignment is refused. The preparer parses
exactly the bounded bytes whose size and SHA256 passed, rather than reopening a
possibly changed path. No detector or model output participates in alignment.

The frozen policy maps twelve publisher types to the existing native prompt
categories:

| Publisher type | Scored category |
| --- | --- |
| email | email |
| phone_number | phone |
| address, street_address | address |
| ssn | government_id |
| account_number | financial_id |
| credit_card_number | credit_card |
| date_of_birth | date_of_birth |
| ipv4, ipv6 | ip_address |
| password, api_key | secret |

The other thirty types are explicitly out of this policy, including names,
generic dates, medical/customer/employee IDs, routing numbers, national/tax IDs,
PIN/CVV and public URLs. A policy-negative document can still contain those
annotations. It is **not a document with no personal information**. The source
has no passport/driver-license annotations for qualifying those native prompts.
Publisher labels have not been independently relabeled, and annotation
completeness is not guaranteed by exact string alignment.

Selection uses SHA256 of a fixed seed, source UID and original source digest.
It takes up to two positive documents and one policy-negative document per
domain, then adds hash-ranked sources until every included publisher type has
at least six source documents, with a maximum of 192. This intentionally
balances domain/type coverage; pooled metrics will not represent natural
prevalence. Two domains have no eligible policy-negative source.

The frozen local corpus has **153 documents: 108 positive, 45 policy-negative,
250 values, 47 domains**. The public [coordinate manifest](../benchmarks/prototypes/pii/gretel-validation-v1/manifest.json)
contains source/entity hashes, labels and offsets, with no source/entity text.
Maximum selected length is 851 Unicode codepoints. Its SHA256 is
`1f535deee05a2c5785bd3201e6b50e3bd349996e33802855314a39dff127491e`.
[Admission receipt](../benchmarks/prototypes/pii/gretel-validation-v1/source-admission.json)
records all source/selected inventories, selection rules and code hashes from
preparation source `f68cd05`.

## Verification and reproduction

Fourteen offline contract tests pass. They cover exact Unicode offsets,
missing/overlapping repeated values, normalization refusal, malformed/executable
annotation strings, unknown/duplicate labels, overlapping gold, schema/bounds,
duplicate source IDs/texts, deterministic input-order-independent selection and
insufficient type coverage. Two full preparations produce byte-identical corpus
files. A changed parquet refuses before output creation; an existing output is
preserved. No model prediction is needed for these checks.

```sh
python3 scripts/test-pii-domain-quality.py
python3 scripts/replay-pii-domain-admission.py
```

Without arguments, replay checks public coordinate metadata, source/policy
identity, labels/bounds, selection idempotence and selected inventories. CI
runs this mode without PyArrow or model downloads. Full literal annotation
checks require the exact explicitly prepared local corpus:

```sh
python3 scripts/replay-pii-domain-admission.py \
  --corpus /absolute/new/admitted/corpus.json
```

This local replay checks the original corpus hash, every retained literal
annotation/offset and source digest against the public coordinate projection.
Neither replay mode downloads data or runs inference.

For independent full admission, explicitly download the pinned validation file
from the source repository, then use a new environment/output directory:

```sh
uv venv --python 3.12.15 /absolute/new/pii-data
uv pip install --python /absolute/new/pii-data/bin/python \
  --require-hashes --no-deps --only-binary :all: \
  --index-url https://pypi.org/simple \
  -r benchmarks/prototypes/pii/gretel-validation-v1/requirements.lock
/absolute/new/pii-data/bin/python scripts/prepare-pii-domain-quality.py \
  --validation-parquet /absolute/pinned/validation.parquet \
  --output /absolute/new/admitted
```

## Publication boundary

The first unpublished push was blocked by GitHub push protection because the
public synthetic source contains credential-shaped values. Protection was not
bypassed, and no credential was tested. The raw corpus was removed from the
unpublished commit; unchanged raw source/model input remains in ignored local
artifacts. Public artifacts contain hashes, labels and coordinates only. This
changes publication, not source text, annotations, selection or model input.
Future native output text also stays local; public observations must omit raw
text and entity values.

## Native evaluation and results

`prepare-pii-domain-eval.py` freezes the exact signed CLI, selected corpus,
admission receipt, code and local model/runtime bytes before any native call.
`evaluate-pii-domain-quality.py` first measures actual rule admission through a
fresh explicit synthetic library, then completed **918 inspections**:
153 sources × CPU/Core ML × thresholds 0.3/0.5/0.7. Model and combined masks are
scored separately; all final masks equal the union of actual learned and actual
shipping-rule masks. All native calls exit normally. The signed product is
`7e21e0f`, frozen evaluation tooling is `4994f97`, and the binary SHA256 is
`45ef3df1e3bd2ea4fad804feeded7130193ce1a4e240644f8b806e12db18c418`.
No product source, native app build or installation changes.

| Backend / threshold | Learned values fully masked | Combined values fully masked | Policy-negatives flagged | Combined character precision / recall |
| --- | ---: | ---: | ---: | ---: |
| Production rules | — | 45/250 | 0/45 | 81.59% / 14.17% |
| CPU 0.3 | 229/250 | 229/250 | 42/45 | 60.62% / 93.49% |
| CPU 0.5 | 189/250 | 189/250 | 25/45 | 74.48% / 72.23% |
| CPU 0.7 | 111/250 | 118/250 | 4/45 | 86.53% / 37.25% |
| Core ML 0.3 | 227/250 | 227/250 | 42/45 | 58.97% / 92.63% |
| Core ML 0.5 | 186/250 | 186/250 | 26/45 | 73.84% / 72.66% |
| Core ML 0.7 | 109/250 | 115/250 | 3/45 | 87.15% / 37.21% |

At CPU 0.7 only 2/26 email values and 1/36 address values are fully covered.
A partially masked identifier does not count as protected. These are 250
values across 153 documents, not 918 independent quality examples. Rule
protection has a narrower intended scope than the selected policy; its low
recall alone does not justify replacing it. Policy-negatives contain other
annotated PII, so these flags measure disagreement with the stated policy,
not a universal definition of harmless text.

Exact combined masks agree on 135/153 sources at 0.3, 142/153 at 0.5, and
146/153 at 0.7. Model masks alone agree on 145/153 at 0.7. CPU512/CoreML128
window contexts differ on longer documents; this run does not isolate context
effects from provider numerical effects. Differences remain in the receipt;
no backend substitutes for another. The earlier short 72-source exact mask
parity remains separately scoped.

The [complete receipt](../benchmarks/pii-domain-validation-v1.json) binds ten
public files and every native operation. Published observations contain only
source/output hashes, model metadata, labels and original-source codepoint
ranges. Raw source, rendered text and original JSON remain local. All 918
public metric/union/flag checks replay without source text or model packages:

```sh
python3 scripts/test-pii-coordinate-quality.py
python3 scripts/replay-pii-domain-quality.py
```

Eight new coordinate-scorer tests pass, including agreement with the literal
scorer on owned Unicode examples. Combined with the 14 source-admission,
14 existing literal-scorer and ten native-output tests, 46 offline tests pass.
Full local replay independently rechecks every original stdout/stderr hash,
UTF-16 conversion, rendered text, model/compute/threshold identity, flags and
actual rule/learned union, and matches every metric with both scorers:

```sh
python3 scripts/replay-pii-domain-quality.py \
  --corpus /absolute/new/admitted/corpus.json \
  --native-output /absolute/original/native-evaluation
```

Returned suppression flags do not qualify actual screenshot/audio admission.
Operation times include startup/loading and uncontrolled host activity; public
alternative-model asset preparation overlapped some Core ML calls. No latency,
energy or physical GPU-placement advantage follows. Stronger Small/Base
candidates are prepared for separate local reference comparison; no candidate
is selected for production.

```sh
python3 scripts/prepare-pii-domain-eval.py \
  --binary /absolute/signed/oswindctl --binary-sha256 EXACT_SHA256 \
  --binary-source EXACT_40_CHARACTER_SOURCE_COMMIT \
  --corpus /absolute/new/admitted/corpus.json \
  --source-admission /absolute/new/admitted/source-admission.json \
  --model-dir /absolute/pinned/model \
  --runtime-library /absolute/pinned/libonnxruntime.1.24.2.dylib \
  --output /absolute/new/native-plan
python3 scripts/evaluate-pii-domain-quality.py \
  --plan /absolute/new/native-plan/plan.json \
  --corpus /absolute/new/admitted/corpus.json \
  --source-admission /absolute/new/admitted/source-admission.json \
  --output /absolute/new/native-evaluation
```

Keep code, corpus, admission receipt, model assets and binary immutable during
the ordered evaluation. Longer sources can have different CPU512/CoreML128
window contexts, so backend mask agreement is measured and reported, not
assumed or required. No favorable backend substitution or automatic retry.
Raw operation times do not establish latency/energy or physical GPU placement.
No quality operating point, production admission, release or competitor
acceptance is established. F047 remains TODO.
