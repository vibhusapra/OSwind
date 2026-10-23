# Benchmark protocol and results

No overall ranking against other products has been established. Competitor features are documented in the research report; competitor runtime performance has not been measured.

## Reproduce retrieval

```bash
swift build -c release
.build/release/oswindctl benchmark --count 1000 --output benchmarks/oswind-1000.json
.build/release/oswindctl benchmark --count 10000 --output benchmarks/oswind-10000.json
```

The benchmark creates and removes an isolated temporary store. Twelve topic templates are repeated to fill the requested record count; 12 queries run three times across keyword, semantic and hybrid retrieval. It reports ingest throughput, disk bytes, hit rate@5, MRR@5, and p50/p95 including query embedding. Relevant items are any record with the expected topic label. This is a fast regression/scaling fixture, not a representative user study. Repeated topics can crowd out other sources and overstate recall. Semantic search scans every filtered vector.

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
