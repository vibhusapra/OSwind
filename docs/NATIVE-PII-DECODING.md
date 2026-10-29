# Native PII decoding and Core ML prototype

[PR #72](https://github.com/vibhusapra/OSwind/pull/72) adds native output decoding and source-bound whole-grapheme masks. A separate native prototype now runs the pinned model with fixed 128-token inputs and varying output word counts through Core ML. **Capture, import, query, export and setup do not select this model/decoder yet.** F047 remains TODO; classifier quality is still the [earlier validation result](PII-EVALUATION.md).

## Output contract

`PIIDecoding` accepts a batch-one tensor shaped **1 × exact source word count × 12 labels × 3 start/end/inside logits**. Source preparation reuses the [native word splitter](NATIVE-PII.md). Every tensor cell must be finite; wrong layout, labels, batch, word count or element count refuses the entire result.

The implementation preserves the actual pinned GLiNER decoder's semantics: start/end probabilities are strictly above threshold; inside probabilities may equal threshold; confidence is the minimum participating probability. Flat/single-label overlap selection uses stable candidate order. Token decoding does not apply the unrelated span-model `max_width` cap. A 13-word constructed span and equal-score boundary/class cases verify this distinction. Inputs are bounded to 512 words and 16,384 candidates; exhaustion or cancellation returns no partial detection.

Selected raw word ranges can split combining sequences or joined emoji. Mask preparation verifies the exact source SHA256, expands ranges to complete original composed characters, merges overlapping/touching masks and replaces from the end. Unmasked bytes remain exact. A source edited into a canonically equivalent spelling still refuses. The result's media-suppression flag is true whenever a mask exists; production screenshot/audio paths do not consume that flag yet.

The binding covers **the source supplied to decoding**. A future backend must carry that same source with the tensor that produced it and fence library, policy, model and record generations. The primitive alone cannot verify that a caller paired the correct model output with its source.

## Actual native execution

The model remains [GLiNER PII Edge at the pinned revision](https://huggingface.co/knowledgator/gliner-pii-edge-v1.0/tree/9b7f39b0a2da971a5beea78d35f1539d4009c891). No weights or third-party runtime headers are committed. The standalone C API executable loads the explicit checksum-verified ONNX Runtime 1.24.2 library. It can now write an exclusive binary output fixture after every numerical check passes; truncated, malformed or nonfinite native/reference data refuses parsing.

| Path | Validation sources | Calls in one completed run | Largest logit difference from original CPU |
| --- | ---: | ---: | ---: |
| Native CPU, original dynamic model | 72 | 144 | 0 |
| Native Core ML, fixed 128 token input/dynamic word output | 72 | 144 |0.000190735 |

Two native CPU exports are retained; the follow-up adds nonfinite-reference refusal and repairs a Python docstring warning. All 92 input/expected-span/mask cases stay identical. They contain 72 model-validation cases and 20 constructed-logit cases. The second native CPU export plus constructed logits yields 276 threshold comparisons. Actual Core ML output tensors add 216 comparisons on the **same 72 validation sources**. Native Swift produces identical span boundaries, labels and masks in all 492 comparisons. Maximum confidence error is 0 for CPU and 2.0862e-6 for Core ML, within predeclared 1e-6 / 1e-3 tolerances respectively. No reserved test predictions are opened.

The Core ML experiment changes only input/output metadata and masked padding. Operator/initializer bytes remain identical. Token inputs have shape1× 128; pad ID is 50283, attention/word masks are 0 on padding, and actual word lengths remain unchanged. Output word count stays dynamic. Observed original inputs contain 49–78 tokens and 6–24 words. This does not qualify other buckets or long-source coverage.

Each Core ML session profiles 20 distinct Core ML EP partition names and 82 CPU node names. Across 144 calls, profiles record2,880 Core ML EP and11,808 CPU node invocations. The policy is MLProgram / CPUAndGPU plus CPU. **Provider assignment does not prove physical per-operation GPU placement.** All 24 sessions emit retained framework warnings about rank/unbounded-dimension/matmul paths despite correct results on this cohort. Peak owned-process RSS reaches 831 MB; shared framework daemons, residency after release and physical energy are not measured. These sequential exploratory timings do not establish a speed or power win. The original dynamic-model construction failures remain valid retained observations; this is a new bounded path.

## Qualification

[Frozen-source report](../benchmarks/native-pii-decoding-v1.json), source f2d0a74 / schema 22:

- **984 defined tests: 982 passes, two explicit skips, zero failures.** The skips are physical system-audio opt-in and unavailable locked/thermal visual admission; device settings remain unchanged.
- **132 selected TSan passes**, no skips/failures/race reports. A separate optimized build passes all 28 PII primitive cases with the same confidence results. The TSan selection does not instrument the prebuilt ONNX Runtime/Core ML internals.
- All **six ordered package/process operations** pass. The 33-file signed app/ZIP matches normalized raw payloads and the complete extracted tree. Installed/staged bytes remain unchanged; full owned command-path and current-artifact-root image inventories are empty. Shared system framework services are outside that process scope.
- The signed CLI preserves 459/501 top 1 and 498/501 top 5 on the existing opened visual corpus, with exact model/corpus identity, indexing/scopes/reopen. This is functional compatibility, not fresh holdout or paired performance evidence.
- Both exact-source CI jobs pass in [run 40816013794](https://github.com/vibhusapra/OSwind/actions/runs/40816013794). Later documentation CI is separate.

Four offline interchange tests run in CI without weights, model dependencies or network. The preceding parser has one retained failed case accepting a nonfinite expected reference; the corrected parser refuses it. The original measured reference tensors are finite, and both completed model exports remain valid and numerically identical.

## Reproduction and remaining work

The [prototype recipe](../benchmarks/prototypes/pii/README.md) includes public CPU/Core ML tensor fixtures, the exact native executable source, preparation/export tools, historical Core ML diagnostic and all warning/operation receipts. Ordinary native decoder tests use the committed synthetic tensors and require no weights. Rebuilding inference observations requires the separately locked local model environment.

Next: implement verified production runtime/model loading, serialized backend ownership, cancellation/drain/idle release and generation fencing; cover long sources without truncation; integrate every ingestion/egress path and media suppression; add accurate setup/failure UI. Independent representative OCR/ASR/desktop/multilingual quality, older supported Macs, physical power and matched competitors remain open. Input/output compatibility does not resolve the model's false positives or establish broad PII protection.
