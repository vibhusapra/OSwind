# Public domain privacy validation

This follow-up broadens the [72-source authored fixture](NATIVE-PII-QUALITY.md)
with externally authored synthetic English documents. **Data admission is
complete; native model quality results are pending.** No threshold, privacy
policy or production learned-redaction mode is accepted by preparing data.

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

## Planned native evaluation

`prepare-pii-domain-eval.py` freezes the exact signed CLI, selected corpus,
admission receipt, code and local model/runtime bytes before any native call.
`evaluate-pii-domain-quality.py` first measures actual rule admission through a
fresh explicit synthetic library, then makes **918 planned inspections**:
153 sources × CPU/Core ML × thresholds 0.3/0.5/0.7. Model and combined masks are
scored separately; every final mask must equal the union of actual learned and
actual shipping-rule masks. Failed calls/refusals retain their original receipt.

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
No quality, production admission, release or competitor acceptance follows from
this data/preparation work. F047 remains TODO.
