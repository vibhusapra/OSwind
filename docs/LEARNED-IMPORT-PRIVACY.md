# Experimental learned privacy for imports

This implements additional local text masking for new OSwind JSON imports, saved Limitless API text responses, and version 1 collector batches. It is off by default. It does not rescan existing history, alter captured pixels or audio, protect live capture, or guard remote model egress. F047 remains incomplete.

The pinned GLiNER Edge service runs through the native ONNX runtime, with explicit CPU or Core ML policy. Core ML requests acceleration; this does not establish that every operator runs on the GPU or ANE. Prepared assets are verified offline. Import never downloads a missing model or falls back to an ordinary unscanned import.

## Use

Prepare models explicitly in Settings → Models, or with `oswindctl pii prepare`. Enable additional import masking in Models Settings and choose compute and sensitivity. The initial displayed threshold is 0.5; no threshold has met our privacy acceptance target. Lower thresholds also hide ordinary text. Configuration applies prospectively and is saved per library.

CLI imports honor the strict saved import configuration. Explicit options select an experimental import scan:

```sh
oswindctl --data /absolute/owned/library import /absolute/owned/input.json --json \
  --pii --pii-compute coreML --pii-threshold 0.5
oswindctl --data /absolute/owned/library import-limitless /absolute/owned/page.json --json \
  --pii --pii-compute cpu --pii-threshold 0.5
oswindctl --data /absolute/owned/library collect --stdin \
  --pii --pii-compute coreML --pii-threshold 0.5 < /absolute/owned/batch.json
```

`--pii-cache-root DIR` selects an already prepared cache. It requires `--pii`; compute and threshold are required when `--pii` is supplied. With no CLI override, saved configuration applies. Existing history-free `pii inspect` stays independent of libraries.

Successful JSON results include optional `learnedPrivacy` metadata: pinned model ID, requested compute, threshold, sources, sources with any masking, scanned string fields, and inference windows. These counts are not sensitive-value recall. A changed source can still contain missed PII. Results without additional scanning retain the old JSON shape.

## Admission and source handling

One shared library activity reservation spans input reading, decoding, model verification/inference and publication. The model session is shut down and joined before the GUI/CLI releases that reservation. GUI privacy/import-configuration changes cancel the actual worker; switch, lock and quit drain it. No SQL or activity-state mutex spans model inference. Settings and complete target/linked-parent payloads are pinned before preparation; changed settings, target edits, curation changes, inserts/deletes, root replacement, cancellation or a released reservation refuse publication. The entire batch commits in one transaction after the final checks.

The scanner walks typed Memory string leaves in stable order and constructs an original-text document with field labels. JSON escape sequences are never treated as model offsets. Main text, title, URL, app/display, tags, transcript model/speaker/diarization metadata, frame/region OCR and recap metadata are covered. Paths, imported vectors and flat regions are discarded. Validated enum values and structurally opaque UUID/hash identities are excluded from neural framing. Other identity strings are inspected; a detected immutable identity refuses the batch rather than breaking links or changing application identity.

The service response is independently checked against exact UTF-8 source bytes, model/compute/threshold, scalar boundaries, finite spans and reconstructed whole-character masks. Original-source pattern checks are always added in this optional mode, even if ordinary pattern redaction is disabled. Learned subspans remain propagation seeds when a larger pattern mask overlaps their trigger. Exact detected literal values propagate across duplicate fields. There is no normalization-based substitution or raw fallback.

Joined visual text masks project onto original frame offsets before replacement. Affected OCR regions are discarded and source text is rebuilt from sanitized frames. Original spoken/split-credential checks run before learned masks can hide their triggers; detected transcript changes conservatively suppress all timed segment text. Timing, geometry and immutable IDs are preserved or validation refuses the batch. Imports never retain referenced image/audio/video files.

A source has explicit experimental limits: 512 KiB serialized typed JSON; a framed document of at most 128 KiB / 32,768 scalars / 8,192 words; 4,096 string fields; 256 windows / 65,536 framed tokens / 16,384 model spans; 256 unique duplicate-value seeds / 16,384 duplicate matches; one million field-mask intersections. Exceeding any bound refuses the whole batch. Ordinary import limits are unchanged when this mode is off. Many small metadata fields and duplicate text can hit the framed limit earlier than the main text alone. Large-library throughput and desktop power are not qualified.

## Quality and retained failures

The original 153-document external synthetic English validation and independent model comparisons remain in [PII-DOMAIN-VALIDATION.md](PII-DOMAIN-VALIDATION.md) and [PII-MODEL-COMPARISON.md](PII-MODEL-COMPARISON.md). These do not establish desktop, OCR, ASR or import-framing quality. No operating point has been accepted and no stronger model has been selected.

The first native all-path acceptance attempt at threshold 0.5 missed the authored reserved-domain email in all ten GUI/core import assertions. The complete failed run remains in the ignored local `focused-v4.log`. Direct CPU inspection of the same original text also missed it. A frozen negative explicitly preserves this limitation; a separate independently pinned authored phone fixture tests a learned positive. Passing lifecycle, mask-coordinate or native positive checks does not erase the failed privacy-acceptance result.

A separate Unicode test initially refused a valid model span ending inside a composed character. The import validator now accepts original scalar boundaries and the existing mask layer expands to whole characters. Its earlier failure remains in `focused-v3.log`. Initial test compilation failures remain in `compile-focused-v1.log` and `focused-v2.log`.

## Remaining work

- [ ] Accept a sensitivity/model policy against representative desktop OCR, speech and metadata, with held-out negatives, value recall and over-redaction costs.
- [ ] Evaluate import framing independently; compare per-field/original-context scans without tuning on a reserved test set.
- [ ] Integrate learned protection into live screen/audio admission, with saved-policy and source-revision fences.
- [ ] Treat actual image/audio/video content and verify no sensitive media retention.
- [ ] Protect remote-model egress and exports consistently without implying imports cover those paths.
- [ ] Add model/settings provenance per persisted record, migration/reindex/rescan controls, throughput and physical power measurements.
- [ ] Finish the broader all-writer admission audit, including CLI note preparation.
- [ ] Resolve the independent encrypted-image detach failure: PR83 source94f60b0 CI passed, but publication28a95f8 run40889784746 failed `NativeVaultQueryRecoveryTests` line94 on normal `hdiutil` exit16. The cause remains unproven; no forced detach or altered cleanup policy was added.
