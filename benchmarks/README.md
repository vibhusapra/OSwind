# Benchmark protocol and results

No overall ranking against other products has been established. Competitor features are documented in the research report; competitor runtime performance has not been measured.

## Reproduce retrieval

```bash
swift build -c release
.build/release/oswindctl benchmark --count 1000 --output benchmarks/oswind-1000.json
.build/release/oswindctl benchmark --count 10000 --output benchmarks/oswind-10000.json
```

The benchmark creates and removes an isolated temporary store. Twelve topic templates are repeated to fill the requested record count; 12 queries run three times across keyword, semantic and hybrid retrieval. It reports ingest throughput, disk bytes, hit rate@5, MRR@5, and p50/p95 including query embedding. Relevant items are any record with the expected topic label. This is a fast regression/scaling fixture, not a representative user study. Repeated topics can crowd out other sources and overstate recall. Exact semantic search scans every filtered vector; Automatic may use the optional native index for larger unfiltered archives.

Initial debug result on Apple M5 Max/macOS26: 1,000 rows ingested at ~116 records/s; ~7.75 MB database directory; hybrid p95 ~7.1 ms, hit@5 1.0, MRR .917. Keyword beat hybrid on this fixture. Semantic-only hit@5 .583 is a known quality limitation. Results must be regenerated after retrieval changes; retain build configuration with reported results.

## Full comparison gates

1. Pin each product version, OS/hardware, display scale, inference model and power profile.
2. Use identical public/synthetic screen traces, audio clips, activity/idle periods and privacy fixtures. Keep competitors' default and tuned runs distinct.
3. Measure index lag, transition capture recall, OCR CER/WER, audio WER/RTF, query p50/p95/cold start, Recall@k/MRR/no-evidence abstention, source correctness, CPU/RSS, bytes/hour and power with a physical meter or supported profiling setup.
4. Run sustained active, meeting, idle and low-power sessions and a 24-hour fault/soak test. Test sleep, restart, permission revocation, full disk, model failure, import interruption and audio hardware changes.
5. Store raw logs and workload manifests, explain unmeasured axes, and avoid composite rankings until weights and gates are explicit.

`idle-debug.json` samples a paused debug process while the Mac is locked; it is not an active capture or battery benchmark. `ps` CPU values are lifetime averages, not interval energy measurements.

## Diverse relevance fixture (local model comparison)

```bash
.build/release/oswindctl eval-retrieval --fixture benchmarks/fixtures/desktop-retrieval-v1.json --output benchmarks/relevance-apple-v1.json
.build/release/oswindctl eval-retrieval --fixture benchmarks/fixtures/desktop-retrieval-v1.json --model qwen3-embedding:0.6b --output benchmarks/relevance-qwen3-v1.json
```

The authored fixture contains 32 fictional desktop memories and 35 queries: 16 paraphrases, 4 code questions, 8 multilingual questions, 3 filtered questions and 4 unanswerable questions. Correct IDs are hand-labeled. Each mode runs three repetitions; all calls include query embedding and retrieval. This is a small regression fixture, not a held-out generalization study. Ranking was tuned using this fixture; results therefore require validation on an independent corpus. `history/` preserves results before the fusion correction.

Measured on M5 Max, macOS 26.6.2, release build:

| Model / mode | Recall@5 | MRR@5 | p95 |
| --- | ---: | ---: | ---: |
| Apple / keyword | .839 | .763 | .112 ms |
| Apple / hybrid | .871 | .720 | 4.694 ms |
| Apple / semantic | .565 | .358 | 4.541 ms |
| Qwen3 / hybrid | 1.000 | 1.000 | 92.207 ms |
| Qwen3 / semantic | 1.000 | 1.000 | 98.249 ms |

Qwen3-Embedding 0.6B uses 1024-dimensional normalized vectors; full model digest, fixture SHA256, timings, per-query IDs/scores, warnings, index time and storage are retained in JSON. `ollama ps` reported 100% GPU memory residency during the measured workload. This confirms residency, not a kernel-level utilization or energy measurement.

All modes returned candidates for every unanswerable query (no-evidence empty rate 0). Candidate retrieval is not an answer-confidence decision: answer abstention/citation correctness must be evaluated separately. No competitor binary was run. These results do not support a top-three or state-of-the-art claim.

## Conversation process smoke

`python3 scripts/conversation-smoke.py .build/release/oswindctl` tests persistence, source identity, follow-up subject context, Markdown export/0600 permissions and erasure across separate CLI processes. It defaults to no-model evidence mode for CI. Optional `--provider apple` or `--provider ollama` with `--output PATH` runs installed local generation and asserts the owner/deadline facts and [1] citations. `conversation-local-v1.json` records one measured successful scenario per provider. Missing citations, false abstention and answering the earlier question were found and corrected while developing this fixture; it is a regression smoke, not a held-out accuracy benchmark. Guided citation structure does not prove the text follows from its cited source.

## Exact vector scaling stress

```bash
.build/release/oswindctl benchmark-vectors --count 100000 --dimensions 1024 --output results.json
```

This creates an isolated SQLite archive with deterministic normalized random vectors in the real multi-model table. It measures 3 exact self-match queries repeated 3 times: all candidates (threshold -1), ordinary threshold .25, and a half-archive app filter. It deliberately excludes model inference and natural-language relevance. The all-candidate case stresses ranking memory; random vectors with threshold .25 mostly retain only the exact match. Few timing samples, warm filesystem caches and ordinary host activity limit p95 precision.

Paired development runs on M5 Max/macOS26.6.2:

| Records / path | Before p95 | After p95 |
| --- | ---: | ---: |
| 10k / all candidates | 12.43 ms | 12.95 ms |
| 100k / all candidates | 125.73 ms | 115.09 ms |
| 100k / threshold .25 | 119.24 ms | 108.40 ms |
| 100k / app filtered | 98.92 ms | 86.85 ms |

100k process peak RSS fell from ~36.2 to ~24.8 MiB; this is the benchmark process, excluding OS file cache, the app and model daemons/GPU memory. Database directory size was ~533 MB. The first heap implementation regressed timing and is retained in `history/vector-scaling-100000-heap-first.json`; skipping ID/timestamp decoding for candidates that cannot enter the heap improved it. Small-run timings remain mixed, so this is not a broad speedup claim. Every query retained exact top-1 identity; brute-force unit tests check nontrivial top-k/filter/tie behavior. This remains O(n) scanning, not ANN, and does not measure capture contention or power.

### Million-vector gate: failed

`vector-scaling-1000000.json` records a real release run of 1,000,000 × 1024-dimensional vectors: ~5.33 GB database directory, ~235 seconds ingest, ~25 MiB benchmark-process peak RSS. Exact top-1 remained 1.0, but all-candidate p50 was ~1.31 s and p95 **22.42 s**. Thresholded p95 was ~1.22 s; half-archive app-filter p95 ~.88 s. The long tail fails the intended interactive-performance target. Its cause was not established; do not attribute it to cold caches without profiling. This historical run retains aggregate timings; the benchmark now also emits per-query/repetition timings and returned IDs for future diagnosis. ANN/partitioning, retained repeatable archives, cold/warm runs and capture-write contention are next gates. No competitor ranking follows from these results.


## Native indexed retrieval milestone

```bash
.build/release/oswindctl benchmark-vectors --count 100000 --dimensions 1024 --indexed --quality-queries 16 --archive .local/ann-benchmark-100000 --output results.json
```

`--archive` retains an explicitly marked synthetic-only archive for repeat runs. Unknown/nonempty directories are refused. Source rows/vector batches resume after interruption; graph construction currently restarts. No model inference occurs in this workload. HNSW uses float16 normalized vectors; live float32 candidates are reranked in SQLite. Automatic keeps small and all filtered scopes exact; explicit `--indexed` tests the approximate path even where slower.

Paired 1024-dimensional release trials on M5 Max/macOS 26.6.2 (`ann-storage-*`):

| Records | Exact unfiltered p95 | Indexed unfiltered p95 | Exact half-app p95 | Indexed half-app p95 | Index preparation |
| --- | ---: | ---: | ---: | ---: | ---: |
| 10k | 13.91 ms | 12.70 ms | 10.78 ms | 55.38 ms | 4.53 s |
| 100k | 132.00 ms | 66.79 ms | 99.41 ms | 399.03 ms | 251.94 s |

Every self-match was top-1. These are nine warm samples per mode; p95 is coarse. Preparation uses at most four CPU workers, not the GPU. The initial 100k build process peaked near 517 MiB; a later reopen/query process after bounding hash-buffer lifetimes peaked near 289 MiB. These are different process lifecycles, not a controlled memory optimization comparison. Snapshots add disk/RAM costs; database and OS cache are separate.

`ann-quality-100000.json` reopens the retained 100k graph in ~153 ms (warm filesystem, not a cold boot). Sixteen deterministic non-self queries per scope compare real parallel-built SQLite/ANN results with exhaustive float32 top-10 ground truth. Recall@10 was 1.0 for unfiltered and half-app queries. Unfiltered p95 was 58.35 ms indexed / 124.12 ms exact; filtered p95 was 456.29 / 105.83 ms. This small random-vector result is neither natural-language relevance nor a guarantee against approximation misses. Counts/statistics, cold starts, concurrent capture and larger realistic archives remain open. A million-vector retained build is in progress; its result is not established.

`native-hnsw-component-*` separately records an initial serial native-only exploration: 100k build ~990 seconds; query expansion 128/512/2048/8192 yielded Recall@10 .156/.431/.850/1.0 on 16 random non-self queries. This motivated the conservative 8192 search budget. Component timings exclude SQLite, filters, validation and reranking and must not be presented as product latency. Full application fixtures now test replay, deletion/update, filters/favorites, >5000-change exact fallback, corruption recovery, store erasure and schema-3 preservation. Twelve cache/retrieval tests also pass ThreadSanitizer. No competitor runtime or power measurement was performed.


## Long-source evidence and generation contract

```bash
python3 scripts/evidence-smoke.py .build/release/oswindctl
python3 scripts/evidence-smoke.py .build/release/oswindctl --provider apple --abstention --output apple.json
python3 scripts/evidence-smoke.py .build/release/oswindctl --provider ollama --model qwen3:4b-instruct-2507-q4_K_M --abstention --output local.json
python3 scripts/chat-provider-smoke.py .build/release/oswindctl
```

`evidence-long-v1.json` records two fictional ~9.9 KB notes with identical opening text and different owners/deadlines at the end. The original prefix-based deduplication hid one note; prefix-only context hid the decisions. Full-source/context fingerprints and query-anchored excerpts preserve both. The current pipeline uses a single generation request, with the current question and fresh excerpts. Earlier user questions affect retrieval/excerpt selection rather than being repeated in generation.

The fixture checks assignments, not just presence of names: North→Lina→Thursday; South→Theo→Monday, with no swapped bindings. It also checks bounded-excerpt warnings, citations, both source IDs, persisted turns, concise final prose, no inference error and an unsupported budget question. These are narrow regular-expression/known-fixture checks, not a semantic entailment grader. Passing cannot establish general factual support, multilingual completeness or abstention accuracy.

After simplifying the prompt, three Apple trials and two versioned Qwen3 Instruct trials passed this fixture including the absent-budget request. Apple answer times were ~0.9–1.3 s. Instruct's first owner answer was ~1.3 s; later responses ~0.12–0.46 s. A million-vector CPU graph build ran concurrently. These few observations are not isolated latency percentiles, controlled cold starts, physical power or competitor measurements. Runtime metadata reports GPU memory residency; it does not measure utilization.

Failures matter: `history/evidence-development-failures.json` preserves observed omissions, a discarded source-by-source Apple experiment that assigned the wrong owner despite valid citation numbers, and unfinished metareasoning from the short Qwen alias. Early keyword-presence checks were too weak. During 23 October 2026 validation, the [registry tags](https://registry.ollama.com/library/qwen3/tags) mapped the installed `qwen3:4b` digest to the [thinking-only model](https://huggingface.co/Qwen/Qwen3-4B-Thinking-2507); its thinking mode cannot be disabled. Setup now uses the versioned [non-thinking Instruct model](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507), [Ollama Q4_K_M tag](https://ollama.com/library/qwen3:4b-instruct-2507-q4_K_M), while retaining explicit user choices. This is a practical baseline choice, not a claim that it is the best current model.

The offline provider smoke checks explicit CLI model/endpoint selection, current-question prompts, one-off app scope and provider output-limit rejection. A failed/limited response does not append a completed chat turn. Real paid BYOK vendor contracts remain unrun. General support checking, model/context budgeting, prompt-injection evaluation and semantic chunk retrieval for long sources remain open.
