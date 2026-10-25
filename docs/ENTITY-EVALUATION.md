# Independent entity membership evaluation

This protocol is frozen before running the actual entity indexer on the selected corpus. It measures the people, organization and place memberships shown by OSwind, including their evidence anchors. It is separate from the authored lifecycle tests and project-alias scaling fixtures. No quality result or acceptance threshold is claimed by preparing the data.

## Corpus and selection

[Few-NERD](https://aclanthology.org/2021.acl-long.248/) provides human-annotated English Wikipedia sentences with coarse and fine entity labels. The [pinned DFKI-SLT dataset card](https://huggingface.co/datasets/DFKI-SLT/few-nerd/blob/205f3e9c9f3577ea2561d43f2f62dc249ab92d5b/README.md) declares CC BY-SA 4.0. Attribution: Ning Ding and coauthors, *Few-NERD: A Few-shot Named Entity Recognition Dataset*, ACL 2021, DOI 10.18653/v1/2021.acl-long.248. This is a projection of that corpus into OSwind's product schema, not a reproduction of the published 66-type benchmark.

The [machine-readable frozen plan](../benchmarks/entity-membership-plan-v1.json) pins revision `205f3e9c9f3577ea2561d43f2f62dc249ab92d5b`, exact Parquet lengths/hashes, selection IDs/hashes, scorer and preparer hashes. Its SHA-256 is `b5b1bc805fdb4780602a15520714ff38aab7c8a56e5f965031c817635c922340`.

All rows, including negatives, are eligible. We select the lowest SHA-256 of `OSwind Few-NERD entity membership v1/SPLIT/ID`, with string ID as the tie break: **256 validation and 1,024 test sentences**. These sizes and IDs are chosen before prediction; they must not change after observing results. Validation is available for future development. Once test results are opened, later tuning must not describe those same examples as a fresh holdout. A public corpus can also have appeared in pretrained models' training data.

Tokens join with exactly one ASCII space. Artificial punctuation spacing can change recognition. Coarse person maps to person, organization to organization, and location/building to place; other labels are outside the target ontology. Contiguous equal fine/coarse IO labels form a gold span. Different adjacent fine types remain separate.

## Score and execution

The primary unit is a **typed name per source**, deduplicating repeated names because OSwind stores one automatic membership per normalized source/entity. Exact name comparison uses NFC, whitespace normalization and lowercase. Micro and per-kind precision, recall and F1 count partial names as false positives and leave the missing full names as false negatives. Negative sources remain in the evaluation.

Anchored membership additionally requires a valid exact UTF-16 source slice, correct surface and one of the gold occurrence ranges for that membership. A repeated name can use any gold occurrence. Invalid surrogate boundaries, wrong offsets or the right name at the wrong occurrence do not count as anchored evidence. These are neither token-level NER nor global person-identity metrics.

The evaluator requires explicit binary and plan SHA-256 values, verifies the selected JSON and scorer hash, creates a new library, and invokes actual CLI import/index. It reads only automatic `apple-nameType` memberships from that owned database. No curated aliases, project definitions, providers, normal history, desktop capture or network calls are involved. **Default privacy remains enabled.** If import redacts or otherwise changes even one source, scoring stops and preserves the failure receipt. A revised protocol must be explicitly frozen before any different treatment; silently removing affected examples or scoring stale gold text is forbidden.

Frozen baseline: product commit `fbe6fac9aae43d11a57bae5af25457a08c0090f9`, staged signed CLI SHA-256 `5413f69d336c16f161882a59b3e8f4e7c6a0851c91cfd24c9822071be21e0b18`, schema22. No product changes are made to improve results before this baseline. CLI wall times include startup and SQLite; imports and indexing are recorded separately. They are observations with uncontrolled caches/host activity, not isolated tagger throughput or energy.

## Reproduce

The scorer and its twelve generated-data admission/process checks use only Python's standard library:

```bash
python3 scripts/entity_quality.py
python3 scripts/test-entity-eval.py
```

Preparation alone needs PyArrow. The supplied lock pins the Python 3.12/macOS arm64 wheel; it is intentionally not a universal dependency lock. The recorded preparation used Python3.12.15 and PyArrow19.0.1. No Hugging Face loader script executes. Downloading requires an explicit flag and exact pinned lengths/hashes; existing different assets refuse replacement.

```bash
python3.12 -m venv .local/entity-eval
.local/entity-eval/bin/python -m pip install --require-hashes --no-deps \
  -r benchmarks/requirements-entity-eval-macos-arm64.txt
.local/entity-eval/bin/python scripts/prepare_entity_eval.py \
  --root .artifacts/entity-eval-corpus --download

python3 scripts/entity_corpus_eval.py \
  --binary /absolute/path/to/the/frozen/oswindctl \
  --binary-sha256 5413f69d336c16f161882a59b3e8f4e7c6a0851c91cfd24c9822071be21e0b18 \
  --plan .artifacts/entity-eval-corpus/plan.json \
  --plan-sha256 b5b1bc805fdb4780602a15520714ff38aab7c8a56e5f965031c817635c922340 \
  --split test --output .artifacts/entity-eval-new-test-run
```

Use an explicitly new output directory. Results retain source admission equality, operation exit status/timing/log hashes, schema, predictions hash and scoring metrics. Raw corpus text/labels, owned libraries and predictions stay local and must retain the corpus attribution/license when redistributed; no corpus text is committed here. Public summaries must not contain normal history or local account paths.

This English encyclopedia projection does not establish desktop/OCR/ASR quality, multilingual coverage, identity resolution, natural meeting recall, PII redaction, competitive placement or feature completeness. Those require separate representative datasets and end-to-end workloads.
