# Local PII model comparison

Three pinned GLiNER checkpoints complete the same 153-document validation set
through CPU ONNX and PyTorch MPS: **six processes, 2,754 validated neural
outputs, 250 labeled values and 45 policy-negative documents**. Base improves
recall at several thresholds while retaining substantial over-redaction under
this policy. No candidate or operating point is selected for production.

[Complete receipt](../benchmarks/pii-reference-models-v1.json) binds 37 public
files. These are reference Python pipelines; the installed app still has the
separately qualified [native Edge inspector](NATIVE-PII-RUNTIME.md).

## Results

Each cell shows **fully masked values out of 250; policy-negatives flagged out
of 45**. CPU and MPS produce identical masks and aggregate metrics at all three
thresholds for every checkpoint.

| Checkpoint | Threshold 0.3 | Threshold 0.5 | Threshold 0.7 |
| --- | ---: | ---: | ---: |
| Edge | 229; 42 | 189; 25 | 118; 4 |
| Small | 220; 38 | 184; 32 | 130; 19 |
| Base | 231; 30 | 207; 26 | 171; 15 |

These are combined model-plus-actual-rule masks. Rules alone cover 45/250 with
0/45 flagged. For example, Base 0.5 covers 18 more values than Edge 0.5 and flags
one additional policy-negative; Small 0.5 covers fewer values and flags more.
Equal numerical thresholds are not calibrated equal probabilities across models.

The policy excludes thirty other publisher entity types, so policy-negatives
can contain other PII. Data is externally authored synthetic English, selected
for domain/type coverage; annotations are not independently relabeled and
model-training overlap is unknown. No public test split or authored reserved
test predictions is opened. This is the same 250 values, not 2,754 independent
quality examples, natural desktop/OCR/ASR acceptance or a competitor ranking.
See the [data and native results](PII-DOMAIN-VALIDATION.md) for the full policy.

## What actually ran

| Checkpoint | Pinned repository revision | Architecture from pinned configuration |
| --- | --- | --- |
| [Edge](https://huggingface.co/knowledgator/gliner-pii-edge-v1.0/tree/9b7f39b0a2da971a5beea78d35f1539d4009c891) | `9b7f39b0a2da971a5beea78d35f1539d4009c891` | Ettin32M encoder; token-level three-channel head |
| [Small](https://huggingface.co/knowledgator/gliner-pii-small-v1.0/tree/d21aad5b4a7ec82b3d0970fd1ac74a12c087d85e) | `d21aad5b4a7ec82b3d0970fd1ac74a12c087d85e` | Ettin68M encoder; token-level three-channel head |
| [Base](https://huggingface.co/knowledgator/gliner-pii-base-v1.0/tree/61726e0ad791dcab3e29339bbec3ad42ded65641) | `61726e0ad791dcab3e29339bbec3ad42ded65641` | DeBERTa-v3-small encoder; markerV0 span head |

The model names are publisher labels. Base has a different tokenizer/input/span
contract that needs an adapter before native integration. Only the reference
library handles it here. The additional Small/Base preparation verifies 14 files,
1,996,651,210 bytes, against pinned sizes and Git/LFS object identities. Weights
are local and uncommitted; publisher-declared model licenses are Apache-2.0.
This work does not distribute a new product model payload. Asset preparation
requires at least 6 GB free space.

The frozen comparison uses GLiNER 0.2.29, PyTorch 2.7.0, ONNX Runtime 1.24.2,
Transformers 4.57.1 and the complete source/runtime pins in the plan. Each process
checks its corpus, actual-rule baseline, 62 source-file hashes and model assets
before loading and after completion. Offline/local-only flags and explicit
CPU-only ONNX providers are used. This is not an OS network-denial test.

MPS runs check every neural parameter and every returned logits tensor is on
MPS, with CPU fallback disabled. Every output is finite before decoding;
tokenization and decoding remain CPU work. All sources fit 512 framed tokens
without truncation. There are 459 checked forward outputs per process.

CPU/MPS model masks, combined masks and typed category/coordinate sets match
on all 153 sources at every threshold, for all three models. Maximum observed
decoded-confidence difference on matching spans is 8.23e-6. Raw-logit numerical
equivalence is not measured. The reference Edge masks also match the actual
native CPU masks on all 153 sources at every threshold. Reference grapheme
expansion uses the pinned `regex` package; general native ICU equivalence is
not assumed from this dataset.

The processes run sequentially after the native 918-call evaluation finishes,
with threshold 0.5 first, then 0.3/0.7 for each source. All six first planned runs
exit 0; no failed run or favorable retry is omitted. Every timing and process
RSS/MPS allocation observation is retained. Timings include validation, Python
and framework work, with fixed ordering and uncontrolled host/caches. They do
not establish a causal backend speed ratio, native app residency or energy.
RSS and MPS driver allocation must not be added as disjoint physical memory.

## Replay and reproduce

The public observations contain hashes, labels and source-bound codepoint
ranges, with no source/entity text. Offline replay checks all 37 hashes,
54 metric groups, actual-rule unions, backend agreement and native CPU/Edge
agreement without model packages or downloads:

```sh
python3 scripts/replay-pii-reference-models.py
```

Fresh inference requires the [locked experimental environment](../benchmarks/prototypes/pii/README.md),
explicit pinned Edge assets, and the exact [locally prepared 153-source corpus](PII-DOMAIN-VALIDATION.md).
Use a new direct child of `.artifacts`; existing receipts must remain intact.
The following stages the exact published scripts and explicitly downloads the
additional Small/Base assets. No inference script auto-downloads them.

```sh
python3 - <<'PY'
from pathlib import Path
import shutil
work=Path('.artifacts/pii-reference-repro-v1')
work.parent.mkdir(parents=True,exist_ok=True)
work.mkdir(mode=0o700,exist_ok=False)
source=Path('benchmarks/prototypes/pii/model-reference-v1')
for name in ['asset-plan-v2.json','prepare-assets-v1.py',
             'evaluate-quality-v1.py','run-comparison-v1.py']:
    shutil.copyfile(source/name,work/name)
PY
python3 .artifacts/pii-reference-repro-v1/prepare-assets-v1.py
```

Rehydrate the public plan's machine-specific paths from repository root. Keep
the same pinned corpus and original shipping-rule mask baseline; new local
plan/report hashes and uncontrolled timings can differ from the original run.
The evaluation code checks every recorded source/asset hash before inference.

```sh
python3 - <<'PY'
from pathlib import Path
import json
root=Path.cwd().resolve();work=root/'.artifacts/pii-reference-repro-v1'
plan=json.loads((root/'benchmarks/prototypes/pii/model-reference-v1/plan.json').read_text())
plan['corpusPath']=str(root/'.artifacts/pii-external-data-v1/admitted-v1/corpus.json')
plan['patternPredictionsPath']=str(root/'benchmarks/prototypes/pii/gretel-validation-v1/observations-v1/pattern-predictions.json')
plan['models']['edge']['directory']=str(root/'.artifacts/pii-model-evaluation-v1/model')
for name in ['small','base']:
    plan['models'][name]['directory']=str(work/'assets-v1'/('gliner-pii-'+name+'-v1.0'))
old='.artifacts/pii-backend-alternatives-v1/'
new=str(work.relative_to(root))+'/'
plan['codeSHA256']={(new+k[len(old):] if k.startswith(old) else k):v
                   for k,v in plan['codeSHA256'].items()}
plan['reproducedFromPlanSHA256']=plan.pop('originalPathBearingPlanSHA256')
(work/'comparison-plan-v1.json').write_text(json.dumps(plan,indent=2)+'\n')
PY
python3 .artifacts/pii-reference-repro-v1/run-comparison-v1.py
```

Full source/UTF-16/rendering acceptance remains in the separate native receipt.
These reference results add compatibility/quality evidence without installing
a backend, changing product code or accepting a production privacy policy.
Production policy/record fences and conservative media admission remain next
implementation gates; F047 and overall v0/top-three acceptance stay open.
