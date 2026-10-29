# Learned PII evaluation

OSwind still uses pattern-based secret protection. The optional learned candidate is **not connected to capture, imports, answers, exports, screenshots or audio**. F047 remains TODO. [Measured results](../benchmarks/pii-model-evaluation-v1.json) identify a useful recall opportunity and two blockers: false positives at the default threshold and a failed native Core ML runtime.

## Validation results

The deterministic, authored fixture contains 216 examples. Only 72 validation examples were scored: 48 positive values across twelve prompt labels and 24 negatives. No predictions were generated or inspected for the 144 reserved test examples. This is a small template contract set, not representative desktop data or verified training-unseen material. Test negatives share source concepts with validation, and some synthetic values repeat across splits. They cannot establish independent natural-data acceptance.

The policy includes contextual contact, government, financial, birth-date, network and authentication identifiers. Names, public URLs, generic dates, amounts and unfilled placeholders alone are excluded. These policy choices matter when comparing systems.

| System / threshold | Fully masked values | Negative examples flagged | Exact typed span F1 | Untyped character precision / recall |
| --- | ---: | ---: | ---: | ---: |
| Current shipping regex | 14/48 (29.17%) | 0/24 | No typed output | 89.01% / 36.65% |
| GLiNER 0.3 | 45/48 (93.75%) | 20/24 (83.33%) | 62.50% | 73.45% / 97.96% |
| GLiNER 0.5 | 42/48 (87.50%) | 8/24 (33.33%) | 76.77% | 83.51% / 79.64% |
| GLiNER 0.7 | 29/48 (60.42%) | 0/24 | 70.13% | 100.00% / 51.24% |

CPU ONNX and PyTorch MPS produce identical aggregate quality metrics at all three thresholds in both completed validation runs. A complete value counts only when every character is masked; a partially hidden identifier does not count. Character coverage ignores category, whereas exact span F1 requires the correct category and full boundaries. At 0.5 all four bank-account values are labeled as phone numbers, and all four `.test` email values are missed. Negative errors are mainly secret labels. None of these operating points has been accepted for automatic production redaction.

The regex baseline is the actual immutable signed CLI from product 9d6f33e, importing/exporting fresh explicit fixture libraries. Its hash is `4b1a152c246356feee97a8a368666aeea3dc2e9dc59709360c9804f2c8d7ff06`. The scorer reconstructs only a unique monotonic mapping between original text and literal redaction markers; it does not replicate the regex or use gold offsets to infer its output. Ambiguous reconstructions refuse scoring. Regex supports fewer categories than this selected policy, so its lower recall does not by itself establish a better replacement.

## Actual Mac execution

The candidate is [knowledgator/gliner-pii-edge-v1.0](https://huggingface.co/knowledgator/gliner-pii-edge-v1.0/tree/9b7f39b0a2da971a5beea78d35f1539d4009c891), revision `9b7f39b0a2da971a5beea78d35f1539d4009c891`. Its publisher declares Apache-2.0; the [Ettin encoder](https://huggingface.co/jhu-clsp/ettin-encoder-32m) declares MIT. [Source/file manifest](../models/gliner-pii-edge-source.json) records exact hashes, sizes and runtime pins. No weights or third-party headers are committed. This token-level configuration uses a 32M ModernBERT encoder and an RNN. The actual FP32 ONNX artifact is 181,078,966 bytes; generic model-card descriptions are not the tensor contract.

- Strict local-only PyTorch CPU versus pinned FP32 ONNX passes on three fixed validation inputs, maximum absolute logit difference `4.1008e-5` against a frozen `1e-3` tolerance. The exported graph's dimension names suggest position-first output, but actual output is **batch × words × classes × 3**. No transpose is needed.
- Neural parameters and output tensors run on MPS with automatic CPU fallback disabled. The same three inputs match CPU ONNX within `5.1499e-5`. Tokenization and decoding still run on CPU.
- In the second full Python validation run, CPU median/p95 prediction is **5.44/6.54 ms**, versus MPS **28.19/87.68 ms**. Whole-process peak RSS is about **828 MB / 1.442 GB** respectively. MPS driver allocation is separately about 1.121 GB. These sequential, small batch-one observations have uncontrolled host/caches and include reference tokenization/decoding. They do not establish a causal backend speed ratio, native app residency or energy consumption.
- A standalone native C++ executable loads the explicit ONNX Runtime 1.24.2 dylib without Python. Thirty CPU forward calls on the three fixed tensors match reference logits exactly; all timings are retained. With profiling enabled, median/p95 warm forward time is **8.60/9.10 ms**, peak RSS **468 MB**. Profiling records 24,630 CPU node invocations, 821 distinct node names. This excludes native tokenization, decoding and application work and is not comparable to the complete Python pipeline.
- The native Core ML MLProgram / CPUAndGPU session **fails during model construction** with execution-plan error `-7`. Capability discovery reports 604 of 831 optimized nodes in 70 partitions, but no forward call succeeds and no provider node execution is recorded. Both native attempts retain this failure. Its cause is unproven. A provider capability report or requested policy is not evidence of GPU/ANE execution. [Official provider options](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html) describe the selected policy.

The FP16 and quantized exports are downloaded and checksum verified, but their quality and native runtime are not evaluated here. No battery/power or competitor workload was run.

## Reproduction and safeguards

The [prototype recipe](../benchmarks/prototypes/pii/README.md) includes the exact dependency hash lock, deterministic corpus, frozen plan, historical compatibility probes, native executable source and public synthetic predictions. Model inference uses local-only files and explicit CPU or CoreML-plus-CPU providers; Azure is never selected. Environment setup and explicitly requested asset preparation may download public packages/weights. This is not an OS network-denial test.

Fourteen offline scorer/generator/plan tests and six asset-admission tests pass. They cover typed versus untyped metrics, partial masks, negative errors, duplicate/missing/changed sources, invalid offsets/scores, Unicode conversion, ambiguous baseline masks, oversized text, changed code/corpus, existing-asset preservation and bounded size/hash verification. CI runs these without installing model dependencies or downloading weights. Code and corpus hashes are checked before model loading or CLI invocation. These plans are local experiment recipes, not signed trust attestations.

Retained earlier failures include two output-layout assertions before scoring and a malformed authored interchange missing `regions:[]`. The corrected harness does not change corpus text, gold labels, thresholds or numerical tolerance. The first native run omitted two initial shape-sweep timing samples; the follow-up records all thirty. Original logs and observations remain in ignored local artifacts.

## Remaining gates

- Implement and independently verify native byte-level tokenization, word offsets, token-level decoding and complete grapheme boundaries. Refuse truncation, stale sources and invalid output without exposing raw sensitive data through a fallback.
- Establish a working native accelerator path, serialized ownership, cancellation, bounded long-source processing and idle/manual model release.
- Tune only on validation; freeze representative independent OCR/ASR/desktop and multilingual acceptance data before opening it. Measure whole-value recall and false-positive cost together.
- Qualify every ingestion and egress path, screenshot/audio suppression, lock/wipe/backup lifecycle and setup/download/license controls. Text span quality is not visual redaction acceptance.
- Re-run relevant native tests/TSan after production integration, then physical desktop/power and matched competitor workloads. Existing product qualification and overall parity/release gates remain separate.
