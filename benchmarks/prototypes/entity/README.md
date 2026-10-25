# Historical native entity prototype

These are the exact measured scripts behind [the prototype report](../../native-entity-prototype-v1.json), preserved with their fixed ignored output paths. They are developer experiments. The application still uses Apple name tagging; these scripts do not install a recognizer into the application.

Prepare the pinned corpus using [the evaluation protocol](../../../docs/ENTITY-EVALUATION.md). Only its validation selection is used here. `stage.py` copies scripts, the public publisher-metadata snapshot and validation data into ignored owned folders. It performs no download or inference, and refuses existing different files. The metadata snapshot's download/like counters are historical; the publisher revision and file digests identify the model.

```bash
python3 benchmarks/prototypes/entity/stage.py \
  --corpus .artifacts/entity-eval-corpus

# Explicit pinned public weights/tokenizer download, about 261 MB.
python3 .artifacts/entity-model-prototype-v1/download-distilbert.py
```

Each inference/conversion script uses the existing locked visual-conversion Python environment recipe. Run from the repository root. macOS Apple Silicon, Xcode and an available MPS device are required. PyPI dependencies may be fetched during environment setup; model inference itself uses local-only files with no Hub/provider fallback.

```bash
PYTORCH_ENABLE_MPS_FALLBACK=0 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  uv run --locked --script .artifacts/entity-model-prototype-v1/probe-distilbert.py
PYTORCH_ENABLE_MPS_FALLBACK=0 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  uv run --locked --script .artifacts/entity-model-prototype-v1/probe-distilbert-v2.py
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  uv run --locked --script .artifacts/entity-model-prototype-v1/convert-distilbert.py
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  uv run --locked --script .artifacts/entity-model-prototype-v1/probe-coreml.py
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  uv run --locked --script .artifacts/entity-model-prototype-v1/prepare-native-fixtures.py

swiftc -O .artifacts/entity-model-prototype-v1/NativeNERProbe.swift \
  -o .artifacts/entity-model-prototype-v1/native-ner-probe-v1
.artifacts/entity-model-prototype-v1/native-ner-probe-v1 \
  .artifacts/entity-model-prototype-v1/distilbert-coreml-fp16-v1/entity.mlmodelc \
  .artifacts/entity-model-prototype-v1/native-inputs-v1.json cpu 3
.artifacts/entity-model-prototype-v1/native-ner-probe-v1 \
  .artifacts/entity-model-prototype-v1/distilbert-coreml-fp16-v1/entity.mlmodelc \
  .artifacts/entity-model-prototype-v1/native-inputs-v1.json gpu 3
```

Output directories are intentionally exclusive; completed experiments are not overwritten. The first decoder is retained because it incorrectly split subwords into independent names. The corrected decoder uses the first piece's tag for the complete word. The conversion checks four authored sentences under both policies; the validation and standalone Swift checks then exercise broader inputs. Float16 CPU output has some label differences from the GPU reference.

Source weights/tokenizer follow the publisher's Apache-2.0 model card. Derived Few-NERD text/labels remain local under the pinned card's CC BY-SA4.0 attribution: Ding et al., ACL2021, DOI10.18653/v1/2021.acl-long.248. No raw corpus text or model weights are committed. These validation experiments establish neither held-out application quality, PII protection, physical power nor competitor performance. A GPU-permitting Core ML policy is not a per-operation placement measurement.
