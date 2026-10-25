# Native entity recognizer work in progress

[PR #56](https://github.com/vibhusapra/OSwind/pull/56) adds bounded tokenization/decoding groundwork and fixes an existing entity-writer Unicode validation defect. The application's recognizer remains Apple's local name tagger. The optional learned model has not been connected to indexing, setup or the UI. Current recognition quality remains the [frozen baseline](ENTITY-EVALUATION.md).

## Whole source anchors

On the tested Foundation runtime, converting an `NSRange` to a Swift `Range` can accept an offset in the middle of a surrogate pair. An isolated substring then becomes a replacement character. The previous entity writer also accepted the base of a combining sequence and part of a joined emoji. Three authored cases replaced valid automatic links; the retained baseline has six failed assertions. Admission now uses the existing composed-character-safe `PassageRange` check before any mutation. Invalid results leave earlier links and source text intact. This prevents new malformed admissions; it does not migrate arbitrary historical or externally modified database rows.

Cased WordPiece retains original UTF-16 offsets across removed controls, supplementary scalars, Chinese characters, whitespace and subwords. Input is bounded at 32,768 UTF-16 units; a word has at most 100 Unicode scalars before becoming one unknown token. Cancellation is checked during processing. Literal model-control tokens cannot become evidence names.

Whole-word windows reserve two positions for model framing and carry at most 254 content tokens, with bounded overlap and explicit progress checks. The first subword label owns its full word. BIO decoding preserves exact original ranges, distinguishes adjacent names and excludes miscellaneous labels. Intermediate token boundaries must be valid Unicode scalar boundaries; emitted name ranges must contain complete composed characters. The current writer does not accept the experimental decoder's method until explicit backend integration is implemented.

## Independent tokenizer reference

The public preparation script reproduces the exact frozen token-ID/UTF-16 reference hash for **256 validation sentences plus six authored boundary cases**. It uses the pinned Rust tokenizers library, without model inference, weights, a provider or normal history. Two small public tokenizer files download only with an explicit flag. Existing different assets or references refuse replacement. Corpus text stays local with its Few-NERD attribution/license.

Prepare the corpus using [the independent evaluation instructions](ENTITY-EVALUATION.md), then run:

```bash
uv run --locked --script scripts/prepare-entity-tokenizer-eval.py \
  --corpus .artifacts/entity-eval-corpus \
  --tokenizer .artifacts/entity-tokenizer \
  --output .artifacts/entity-tokenizer-references.json \
  --download-tokenizer

OSWIND_TEST_ENTITY_VOCAB="$PWD/.artifacts/entity-tokenizer/vocab.txt" \
OSWIND_TEST_ENTITY_TOKENIZER_REFERENCES="$PWD/.artifacts/entity-tokenizer-references.json" \
swift test --filter 'EntityWordPieceTests|EntityNERDecodingTests'
```

The input references hash to `4a37be51c00dde8318a734f8db95be5614f420a5ec8218088f6a8846b1cf9407`. Twelve tokenizer cases, thirteen window/decoder cases and one writer regression are added. The 158-case entity/project/passage/backup selection passes with the real reference enabled. [Partial qualification](../benchmarks/entity-unicode-v1.json) has passing observations for all 844 cases across runs but retains a sleep-interrupted session failure and an awake cancelled-lock counterexample under TSan. The latter blocks release acceptance; later absence does not erase it.

## Learned model candidate

The [pinned source manifest](../models/distilbert-ner-source.json) identifies [dslim/distilbert-NER](https://huggingface.co/dslim/distilbert-NER/tree/dfa2838a127384aabb82ed7719e16dab84c42a2a), an English token classifier whose publisher declares Apache-2.0. No weights are committed. Its training domain differs from desktop text.

[Prototype observations](../benchmarks/native-entity-prototype-v1.json) and [exact measured scripts](../benchmarks/prototypes/entity/README.md) use **validation only**. After fixing a prototype decoder that split subwords into separate names, the compact candidate reaches 66.24% membership F1 and 65.88% anchored F1 on the 256 validation sources, versus 56.29/56.08% for the current Apple recognizer on the same selection. The initial incorrect decoder's 33.57% membership F1 remains in the private observations. This is model/decode development on validation, not fresh held-out or shipped-app quality.

A local Core ML conversion produces byte-identical validation predictions to the corrected PyTorch MPS prototype. Four authored numerical fixtures pass declared checks under CPU-only and CPU/GPU policies. A separate optimized Swift process makes 768 predictions per policy: CPU/GPU has zero active-label differences from its Core ML reference; CPU-only has 15, so equivalent CPU output is not claimed. Observed CPU/GPU median/p95 prediction time is 2.16/2.50ms; process peak RSS is 338 MB. Timings exclude tokenization, decoding, source admission and application work; caches and host activity are uncontrolled. These are exploratory component observations. A compute policy permits GPU execution; actual per-operation Core ML placement and physical power remain unmeasured.

## Remaining implementation

- Verify model-bundle integrity and the native tensor contract; serialize loading/inference and bound queue ownership, cancellation and idle/manual release.
- Connect model identity, compute policy and recognizer version to source-index completion. Preserve corrections, project aliases, erasure, lock and quiet backup/restore; add compatibility fencing where required.
- Provide verified local preparation and native setup controls with accurate download, memory, progress, stop and failure states.
- Select settings using validation. Freeze a fresh test selection before acceptance; the baseline test has already been opened and cannot become an unseen holdout again.
- Measure complete source-to-membership latency, residency/release, long-source coverage and older supported Macs under realistic capture workloads.
- Evaluate PII protection independently. A name recognizer and valid source spans do not establish sensitive-content detection or safe redaction.
