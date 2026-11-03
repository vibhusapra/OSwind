# Local chat model refresh

Current local models address several answer-support failures without changing the app's prompts or retrieval. They also expose remaining citation and first-use limitations. The new setup uses Qwen3.5 4B as the smaller preset and offers Gemma4 E4B as a larger alternative; existing saved model choices remain unchanged. [Preset wiring is validated separately](LOCAL-MODEL-PRESETS.md) from this unchanged-engine comparison.

## Frozen comparison

The [receipt](../benchmarks/local-model-comparison-v1.json), [inputs](../benchmarks/local-model-comparison-inputs-v1.json) and [raw archive](../benchmarks/local-model-comparison-raw-v1.zip) bind runtime `49f259d`, its qualified release CLI and all **700 unchanged runtime/test/dependency inputs**. The host is an Apple M5 Max with 128 GiB physical memory, macOS 26.6.2 and local Ollama 0.40.8.

The two new models each receive the [24 prior diagnostic questions](../benchmarks/fixtures/answer-support-authored-v1.json), using a separate exact copy of the original 16-note corpus, including source IDs, payloads and timestamps. All 48 observed retrieved-source orders match the original baseline. A [new 12-question extension](../benchmarks/fixtures/answer-model-extension-v1.json), frozen before candidate inference, uses eight different fictional records and four providers. The original 48 baseline requests are not repeated.

| Profile | Prior diagnostics | New extension | Failed attempts |
|---|---:|---:|---:|
| Apple Intelligence | Prior baseline retained | 11 responses / 12 attempts | One unavailable-source citation rejected by the app |
| Qwen3 Instruct 2507 · original local preset | Prior baseline retained | 12 / 12 | 0 |
| Qwen3.5 4B · new local candidate | 24 / 24 | 12 / 12 | 0 |
| Gemma4 E4B · new local candidate | 24 / 24 | 12 / 12 | 0 |

All **96 planned attempts** are retained: **95 responses and one refusal**. Every declared positive-support set is retrieved in all **80 applicable cases**. Received extension source order agrees across providers. The 126 citation-number occurrences in returned answers are in range; the Apple refusal is retained separately. Five altered-record controls reject missing failures, duplicates, changed answers, source swaps and model drift. Model/server version, source, plan and runner stability checks pass.

These are mechanical counts, not factual accuracy or citation-support scores. All 95 responses and the refusal were read in Codex source-based engineering review; there are no independent human semantic labels or aggregate semantic accuracy claim.

## What changed in the observed answers

Both new models return Devin for the current Helios owner, Leon for Atlas, and both Nimbus owners plus the no-audio answer with the appropriate distinct citations. They retain the rejected June 14 / approved June 18 distinction and correct false completion premises. This addresses concrete cases where the original Apple/Qwen outputs returned stale or mixed-project owners, omitted an answer, or cited the ownership record for retention.

The new extension exposes additional original-Qwen abstentions despite explicit records: no raw audio, Eli's documentation role, 625 remaining credits, and the requested comparison of retention with migration progress. Both new models return these facts.

Remaining observations are retained rather than hidden:

- Qwen3.5 answers the new media/progress question, then adds an unrequested key-rotation detail with an incorrect supporting citation. Its three longer abstentions also trigger the current citation-warning wording check; warning counts are not semantic scores.
- Apple returns one invalid-source citation on the new absent-address question, which the app rejects. Its media/progress answer also cites the ownership record for a progress claim and omits requested detail.
- Gemma's observed answers are concise and source-aligned in these cases. This small authored set does not establish error-free answers, broad superiority or a product ranking.

The receipt includes 14 exact/qualified observations and every output, including the failure.

## Local runtime and first-use observations

Both new tags resolve to local MLX runners on this host. Existing model digests are unchanged. No provider key, paid inference, cloud alias or user history is used. Official [Qwen3.5 4B](https://ollama.com/library/qwen3.5:4b) and [Gemma4 E4B](https://ollama.com/library/gemma4:e4b) tag pages declare Apache 2.0 and offer runtime-specific variants; the measured tag digests and formats are retained rather than assuming a tag is immutable.

| New tag | Observed download bytes | Reported resident bytes | First observed CLI request | Remaining request median |
|---|---:|---:|---:|---:|
| Qwen3.5 4B | 3,973,305,013 | 4,098,979,348 | 63.13 s | 0.79 s |
| Gemma4 E4B | 9,461,576,343 | 9,434,923,512 | 110.64 s | 0.63 s |

Residency comes from the read-only [Ollama running-model API](https://docs.ollama.com/api/ps), with an 8,192-token configured context. It does not identify the processor used for every operation. Timings are descriptive observations of actual CLI requests: loading, caches, output lengths, sequential model order and host activity are uncontrolled. They are **not a controlled latency/throughput or energy comparison**, and do not establish a ranking. The first-request delays are a real setup consideration; a downloaded model may still need startup before its first answer.

## Scope

The extension was authored after seeing the original failures; it is new to candidate inference, not an unseen natural-user benchmark. Existing per-model `/no_think` logic and inherited model parameters remain unchanged and can differ by tag, so prompt/sampling bytes are not claimed identical across model families. Apple assets are not exported/fingerprinted; Ollama identity is server-reported digest/version rather than a new independent hash of every model weight. Model weights and executables are excluded from the archive; explicitly authored SQLite corpora/settings are included.

All earlier successful benchmarks, reviewers, publishers and packages remain frozen. All 83 feature statuses remain unchanged. Physical capture/energy, full sync, production distribution and complete-v0/top-three acceptance remain open.
