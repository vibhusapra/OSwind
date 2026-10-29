# Native PII input contract

[PR #71](https://github.com/vibhusapra/OSwind/pull/71) adds native tokenization for the [experimental GLiNER candidate](PII-EVALUATION.md) and corrects the shared ByteLevel pre-tokenizer. The recognizer is not connected to capture, import, answers, exports or setup. [Explicit native inspection](NATIVE-PII-RUNTIME.md) now combines inference, decoding and whole-grapheme masks with a drainable model owner. Production capture/egress admission and setup remain open. F047 stays TODO.

## Compatibility

The pinned GLiNER processor splits source text using Python3.12 `\w+(?:[-_]\w+)*|\S`, prepends twelve entity prompts and a separator, then applies NFC and byte-level BPE independently to each word. Native inputs preserve that order. They include token IDs, attention masks, first-subtoken word masks, word count and original UTF-16 source ranges.

The shared Swift ByteLevel implementation previously added a virtual space before **each regex fragment**. Two assertions reproduce extra space tokens before `-` and `b` in `a-b`. The correction adds one space before splitting. Empty input stays empty, literal leading spaces remain exact before combining marks, and unprefixed/non-regex configurations are checked against the Rust implementation. The upstream Apache-2.0 license, original hashes, three-file patch and verification script are preserved. No SwiftPM checkout is modified.

The native splitter uses a generated set of 748 Python3.12 Unicode15.0 alphanumeric/underscore ranges. This avoids silently changing model word IDs when the host's Unicode database changes. Python whitespace includes information separators U+001C–001F; zero-width space remains a model token. Intermediate model words can split a grapheme, as in a decomposed accent or joined emoji. Their offsets are **not** automatically valid redaction ranges.

The independent reference uses the actual pinned GLiNER processor and Rust tokenizer, without model weights or inference. All **181** inputs match native token IDs, attention masks, word masks, counts, byte-exact word text and UTF-16 ranges. They contain the existing 72 authored validation examples plus 109 boundary fixtures; no reserved test predictions are opened. All 748 word-class ranges are compared to the independent reference. References include scripts, controls, combining sequences, surrogate pairs, model-control literals, hyphens and every Python whitespace scalar. This is bounded input compatibility, not universal tokenizer/language or detection-quality acceptance.

The focused **21-case** selection also passes the existing 439 visual-tokenizer references and 32 concurrent native PII encoding calls. Earlier observations remain: one before-fix test/two failed assertions; the first expanded test build has an async-autoclosure compilation error; the corrected focused run initially skips the visual opt-in, then the complete opt-in run passes without skips. Whole-product qualification is recorded separately in the delivery ledger.

[Frozen-source qualification](../benchmarks/native-pii-tokenizer-v1.json) at 2d8d65d passes **964/966 tests with two explicit skips and no failures**, **114 selected ThreadSanitizer tests with no skips/failures/race reports**, and all **six ordered package/process operations**. The skips are the opt-in physical system-audio fixture and unavailable locked/thermal visual admission. The 33-file signed app/ZIP matches normalized raw executables and the complete extracted tree; installed bytes remain unchanged. Current full-command-path owned-process and artifact-root image inventories are empty. On the previously opened 100-photo/501-query visual corpus, the exact current bundle preserves 459 top 1 / 498 top 5, complete indexing, scoped results and reopen. This is functional compatibility, not a paired latency, energy or competitor claim. Both exact-source CI jobs pass in run40809566323; both documentation follow-up jobs pass at f259232 in run40811352542.

## Bounds and ownership

- Loading uses explicit local descriptor-bound files with exact tokenizer/config SHA256 checks, bounded reads and strict in-memory tokenizer construction. No Hub client, model-name resolver, provider or download path is created.
- Input is limited to 4,096 Unicode scalars / 16 KiB; each word is at most 1,024 UTF-8 bytes. The complete framed tensor fits 512 tokens. Oversized, empty/whitespace-only, cancelled or invalid input refuses; no truncated scan is returned.
- Source word coordinates address the original text, before NFC. The immutable tokenizer holds no captured source text after the call; returned word surfaces/tensors belong to the caller. A future owner must serialize backend resources and define cancellation/release and stale-source fencing.
- The twelve labels and framing/control IDs are pinned to this candidate. These checks verify tokenizer assets, not model-weight integrity or inference readiness. No model bundle is added to the application's installer catalog.

## Reproduction

Use the [hash-locked PII environment and verified local asset recipe](../benchmarks/prototypes/pii/README.md) for the [pinned public revision](https://huggingface.co/knowledgator/gliner-pii-edge-v1.0/tree/9b7f39b0a2da971a5beea78d35f1539d4009c891). The native constructor reads only `tokenizer.json` and `tokenizer_config.json`. Reference preparation explicitly verifies those files plus `gliner_config.json`, then constructs the GLiNER processor and local Transformers tokenizer. Transformers may also read optional local tokenizer metadata; use the manifest-verified asset directory from that recipe. No model weights or inference are used. Local-only loading disables Hub/credential fallback.

```bash
python3 scripts/prepare-pii-eval.py --output .artifacts/pii-authored.json
.local/pii-python-v1/bin/python scripts/prepare-pii-tokenizer-eval.py \
  --model .artifacts/pii-model-evaluation-v1/model \
  --corpus .artifacts/pii-authored.json \
  --output .artifacts/pii-tokenizer-reference.json

OSWIND_TEST_PII_TOKENIZER_DIR="$PWD/.artifacts/pii-model-evaluation-v1/model" \
OSWIND_TEST_PII_TOKENIZER_REFERENCE="$PWD/.artifacts/pii-tokenizer-reference.json" \
swift test --filter PIITokenizerTests
```

The frozen reference SHA256 is `38303b8a7caf42592966e850cad0d6f3d054b177a1c914bb25d8580da535b412`; the exact [authored reference file](../benchmarks/prototypes/pii/native-tokenizer-reference-v2.json) is also committed for inspection/replay. The corpus JSON is parsed in full, but only validation text and additional boundaries are tokenized; no reserved test predictions are generated. Existing different references refuse replacement. `--word-table` can independently regenerate/verify `Sources/OSwindCore/PIIWordCharacters.generated.swift`; never run it while a build/test pipeline is active. Ordinary offline tests use tiny synthetic assets and do not download anything. The full real-tokenizer comparison is opt-in until a pinned local tokenizer directory is supplied.

The [native decoder/mask follow-up](NATIVE-PII-DECODING.md) adds tested output decoding and whole-grapheme masks, plus a fixed-token/dynamic-word Core ML prototype. Remaining work includes production backend ownership, whole-source windowing, admission across every privacy ingestion/egress path and independent detection quality. The [measured quality/runtime tradeoff](PII-EVALUATION.md) remains authoritative: component compatibility does not resolve the candidate's false positives or establish general runtime support.
