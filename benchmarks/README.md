# Benchmark protocol and results

No overall ranking against other products has been established. Competitor features are documented in the research report. Pinned rem database-method timings are measured separately below; full competitor app runtime performance remains unmeasured.

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

Hybrid and semantic modes returned candidates for every unanswerable query (no-evidence empty rate 0); keyword-only empty rate was .5. Candidate retrieval is not an answer-confidence decision: answer abstention/citation correctness must be evaluated separately. This relevance fixture did not run competitor binaries. Separate keyword component comparisons below do not support a top-three or state-of-the-art claim.

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

`ann-quality-100000.json` reopens the retained 100k graph in ~153 ms (warm filesystem, not a cold boot). Sixteen deterministic non-self queries per scope compare real parallel-built SQLite/ANN results with exhaustive float32 top-10 ground truth. Recall@10 was 1.0 for unfiltered and half-app queries. Unfiltered p95 was 58.35 ms indexed / 124.12 ms exact; filtered p95 was 456.29 / 105.83 ms. This small random-vector result is neither natural-language relevance nor a guarantee against approximation misses. Counts/statistics, cold starts, concurrent capture and larger realistic archives remain open. The million-vector run completed; its non-self recall gate failed, as recorded below.

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


### Million-vector indexed gate: recall failed

`ann-storage-1000000-indexed.json` retains the full raw run; `ann-million-tail-summary.json` recomputes nearest-rank tails from every retained sample. Ingest took ~267 s, native preparation ~3011 s, ~7.93 GB directory including derived graph, ~2.55 GB process peak RSS. Nearest-rank self-query p95/max was ~207 ms unfiltered / ~165 ms thresholded / ~2065 ms half-app; every self-query retained top-1. These nine samples per mode are not precise population percentiles.

Sixteen random non-self queries per scope recovered **.675 Recall@10 unfiltered / .825 filtered**, against exhaustive float32 SQL ground truth. Nearest-rank indexed p95/max was ~303 / 1438 ms; exact-reference p95/max ~19.15 / 11.89 s. This is a failed recall gate even though indexing reduces latency. A two-second process sample during the reference phase showed time in SQLite overflow-page reads; it does not establish the cause of every tail spike. The graph is retained for query-budget/precision tuning and independent follow-up queries. No large-archive quality or competitor superiority claim follows. Automatic still keeps filtered queries exact; the unfiltered million-record recall limitation remains open until tuning/validation is complete.

## Maintained metadata at one million records

```bash
.build/release/oswindctl benchmark-stats --archive .local/ann-benchmark-1000000 --output statistics.json
```

The command accepts only a marked synthetic vector archive and retains it, including its native graph. Opening may perform the schema-4→5 migration; source/chat/cache preservation has regression coverage. `statistics-million-v2.json` compares maintained SQL metadata with the previous combined aggregate and application-count scans on the same archive, five samples each. Maintained metadata p50/p95/max was ~.019/.049/.049 ms versus ~179.1/190.5/190.5 ms for the old SQL scans. Including the small archive's file enumeration had ~.128/1.107/1.107 ms p50/p95/max. Reopening took ~.004 s. The initial `statistics-million.json` preserves the one-time migration run (~.90 s) and its historical quantile estimator. This fixture has two app names and few files, not a realistic screenshot filesystem.

A separate read-only development profile during graph construction observed the old combined query at ~2.99 s initially / ~151–152 ms later, plus app counts at ~160 ms initially / ~31–35 ms later. It was not a controlled cold-cache run. Neither backend benchmark is a whole-UI latency claim. The app now publishes hits independently and coalesces file traversal, with storage freshness shown. Media-heavy traversal, sustained capture contention and actual native interaction still require measurement.


### Timing estimators

New benchmark reports declare `latency_quantiles`: median averages the center pair for an even sample, p95 uses nearest rank `ceil(.95*n)`, and max is reported explicitly. For fewer than 20 samples, p95 is the slowest observed sample; it is not a reliable population-tail estimate. Earlier reports used the lower sample at `floor((n-1)*.95)`, which can understate a small run's tail. Historical artifacts remain intact. `ann-million-tail-summary.json` contains a source hash and recomputed quantiles from the same raw million-vector measurements; no observations were rerun or dropped. The failed recall values are unchanged. `statistics-scan-development.json` preserves the separate read-only SQL profile under build load.


## Metal exhaustive-scoring component prototype

```bash
mkdir -p .artifacts
swiftc -O -parse-as-library scripts/metal-probe.swift -o .artifacts/metal-probe
.artifacts/metal-probe benchmarks/ann-storage-1000000-indexed.json result.json
```

`metal-component-100000.json` and `metal-component-1000000.json` exercise MPS float32 matrix-vector scoring, a CPU top-200 heap and float32 cosine reranking against the already recorded SQL ground-truth IDs. Each has 16 non-self queries per scope; both unfiltered and half-row scopes recovered all exact top-10 IDs in these trials. The input reference SHA256 is retained. Synthetic vectors are regenerated from the same deterministic seeds directly into shared GPU memory; this bypasses SQLite extraction and the actual product cache.

At one million × 1024 dimensions, the matrix uses 4.096 GB and process peak RSS is about 4.1 GB. Generation took roughly 2.3 s. Full component timings include CPU candidate selection and reranking; command-buffer GPU durations are separate. Inspect the JSON for every observation and nearest-rank tails, including first-use overhead. This is an isolated component, not a delivered end-to-end search improvement or a competitor ranking.

Integration gates: bounded-memory backend choice, durable snapshot format and checksum, mutation replay, erase/revision/identity protection, scope masks/metadata invalidation, power policy, cancellation, fault recovery and whole-path benchmarks. The current shipped preview still uses the native/exact paths; its million-record ANN recall failure remains open. Additional independent queries and real model archives are required even if this component retains 1.0 on the current fixture.

## Metal product path and scope reuse

These runs are on Apple M5 Max, 128 GiB RAM, 18 logical CPUs, macOS 26.6.2, release builds with Swift 6.3.3. The component probe above is separate from these real SQLite/cache/candidate-validation runs.

`metal-storage-100000.json` and `metal-storage-1000000.json` use `7c41ca3`: 16 non-self queries per scope at 100k and 24 at 1m (new seeds count+1009...count+1032). The million-row float32 cache was built from real SQLite pages in 27.04 s, peak process RSS 4.23 GB. Every self identity and exact non-self top-10 neighbor was recovered in these trials. Unfiltered self-query median was 14.63 ms, nearest-rank p95/max 106.34 ms. **Filtered latency failed:** self median 366.89 ms and p95/max 4732.93 ms; non-self filtered p95 841.84 ms. The 100k development run overlapped the unit suite. These initial reports exclude coverage-count costs by passing precomputed counts.

`metal-storage-1000000-v2.json` uses `bd0ec66`, transactional scope-mask reuse and one cached coverage-count scope. It includes actual coverage lookup inside each timer. It reopens the retained graph (2.30 s preparation), rather than measuring a new build. All exact top-10 neighbors were recovered on 24 additional non-self queries per scope (offset 5099). Filtered non-self p95 was 34.06 ms, but mixed self-query scopes caused count-cache churn: median 296.70 ms, p95/max 661.60 ms. This failure led to retaining four recent coverage scopes. Earlier exact/native failures remain preserved.

The current reproduction includes coverage lookup, SQL search, GPU candidate scores, CPU selection and original-vector/live-scope validation; it excludes query embedding, UI publication and model generation:

```bash
swift build -c release
.build/release/oswindctl --data .local/bench-driver benchmark-vectors \
  --count 1000000 --dimensions 1024 --indexed \
  --archive .local/ann-benchmark-1000000 --quality-queries 24 \
  --quality-seed-offset 8193 --output benchmarks/metal-storage-1000000-v3.json
```

`metal-storage-1000000-v3.json` uses `01e6f30` and retains four coverage scopes. It reopens the existing Metal cache in 2.28 s, with 4.23 GB process peak RSS. All self identities and exact top-10 neighbors were recovered on 24 additional non-self queries per scope (offset 8193). Self-query p50/p95 were 14.40/94.92 ms unfiltered, 13.30/13.61 ms thresholded, and 26.82/639.07 ms filtered. Non-self indexed p95 was 77.03 ms unfiltered and 28.92 ms filtered, versus exhaustive SQL reference p95 1046.25/845.04 ms. First-scope construction still dominates the filtered self tail; **that cold/scope gate remains open**. These are sequential development trials with warm retained fixtures, not randomized controlled cache/power experiments.

The first invocation on a **new** archive also ingests and prepares the cache; rerunning a retained archive may reuse it. Disk measurements can include both old HNSW and Metal cache formats. Do not interpret reopen time as fresh build time, a first query as controlled cold-cache latency, or these small synthetic trials as realistic-language quality or a cross-product ranking. Filtered Automatic remains exact while first-scope/source-churn/long-run gates remain open. Scope caches use a transactionally maintained nonce, model/store identity and vector journal sequence; the 20k-row product test verifies other-connection edits/reopen/erasure. Allocation limits and failure fallback are covered separately; no GPU energy comparison was run.

## Pinned rem keyword database comparison

```bash
python3 scripts/compare-rem.py --workspace .local/competitors/rem-benchmark \
  --count 1000 --output benchmarks/comparison-rem-1000.json
python3 scripts/compare-rem.py --workspace .local/competitors/rem-benchmark \
  --count 100000 --output benchmarks/comparison-rem-100000.json
```

The script fetches MIT rem revision `f4f68049a064557bddeb93753f82aa41af776b98` and its pinned SQLite.swift submodule, verifies the upstream DB.swift SHA256, retains its license, and compiles the database methods in an isolated Swift package. The only adaptations are a CLI bundle-logging fallback and an explicit data-directory stub. It does not start the rem GUI, record a desktop, decode video or touch rem user data. Marked build workspaces can be reused; each execution gets a new retained synthetic archive. OSwind source-tree and input-fixture digests are recorded.

Both implementations receive identical title+text and app labels from the 32-document fictional fixture. The 1k/100k archives repeat these documents, so this is a scaling/regression workload rather than independent document relevance. Thirteen authored lexical cases run five times, including two app scopes and one absent query. Query order alternates. Results include hit rate, unique document-label recall/precision, empty rate and raw returned labels; duplicated records are not treated as distinct relevant facts. OSwind uses keyword-only search with no embeddings. Its weighted BM25 ranking and OR-prefix query semantics differ from rem's FTS4 matching/default order; equal success on this narrow fixture does not make the behaviors identical.

| Rows | Backend | Keyword p50 | Nearest-rank p95 | Answerable hit@5 / label recall | Absent empty rate |
| --- | --- | ---: | ---: | ---: | ---: |
| 1,000 | rem methods | 0.193 ms | 0.263 ms | 1.0 / 1.0 | 1.0 |
| 1,000 | OSwind | 0.258 ms | 0.490 ms | 1.0 / 1.0 | 1.0 |
| 100,000 | rem methods | 0.359 ms | 0.515 ms | 1.0 / 1.0 | 1.0 |
| 100,000 | OSwind | 9.045 ms | 16.965 ms | 1.0 / 1.0 | 1.0 |

**OSwind loses this keyword component latency comparison.** Its 100k source insert path also took 15.37 s versus rem's 7.34 s; schemas, derived indexes, privacy/deletion and feature responsibilities differ. Both stores occupy the same process, so process peak RSS is not a per-product memory measure. No full app capture, power, OCR/ASR, compression, UI or current commercial-product runtime comparison is implied. These measurements identify a ranked-keyword optimization gate, not a top-three result. Screenpipe's current source license restricts competing-product use; its documented feature/plan comparison remains separate from this executable MIT reference.


## Weighted keyword cursor follow-up

`cc0551b` uses SQLite's [ranked FTS5 cursor](https://www.sqlite.org/fts5.html#sorting_by_auxiliary_function_results) with the same `bm25(0,3,1,1)` weights. Keyword-only queries now decode their requested limit; hybrid queries retain the larger lexical candidate pool. A regression oracle compares the resulting IDs/order with the old explicit BM25 SQL across five queries, six scopes and three limits (90 combinations), including weighted titles, repeated equal-score rows, app/kind/date/favorite/tag scopes and no matches.

The same pinned rem script/fixture was repeated after this change. Reproduce with the commands above and `comparison-rem-ranked-{1000,100000}.json` output names. All narrow lexical checks still pass for both implementations.

| Rows | Backend | p50 | Nearest-rank p95 |
| --- | --- | ---: | ---: |
| 1,000 | rem methods | .178 ms | .219 ms |
| 1,000 | OSwind ranked cursor | .116 ms | .204 ms |
| 100,000 | rem methods | .290 ms | .454 ms |
| 100,000 | OSwind ranked cursor | 2.535 ms | 7.045 ms |

The observed OSwind 100k p95 improves from 16.965 to 7.045 ms, but **rem remains faster on the large keyword component workload**. Ranking/query semantics and broader store responsibilities still differ. These sequential development runs do not establish a controlled universal speedup or overall product ranking. Original results are preserved.

`relevance-apple-ranked.json` and `relevance-qwen3-ranked.json` repeat the authored 32-document/35-query fixture. Aggregate Recall@5, MRR@5 and no-evidence empty rates are unchanged in all three modes against the published baseline. Apple hybrid Recall@5/MRR@5 remains .871/.720; Qwen3 hybrid and semantic remain 1.0/1.0. Hybrid/semantic no-evidence empty rate remains 0, keyword .5; generative abstention remains a separate open gate. No million-vector rerun is needed for this lexical-only SQL change.


## Scoped query process and local model checks

```bash
python3 scripts/query-scope-smoke.py .build/release/oswindctl
python3 scripts/query-scope-smoke.py .build/release/oswindctl --provider apple
python3 scripts/query-scope-smoke.py .build/release/oswindctl --provider ollama
```

`query-scope-local-v1.json` records one Apple and one pinned Qwen3 Instruct answer on five fictional Comet notes and a clock marker. Each process run verifies source/date/app/tag/favorite boundaries, literal bypass, malformed/conflicting argument failures, actual HTTP/MCP behavior, absolute scope/time-zone persistence, history isolation and standalone-evaluation root isolation. Both model trials return the scoped owner Lina and deadline Thursday, with the two correct source IDs and citations. Scope/source checks are authoritative for the fixture; the simple answer-fact checks are a narrow smoke, not general citation entailment or held-out grounding accuracy. Timing is one development observation per provider, not a latency distribution or energy measure.

Calendar tests inject a fixed clock and time zone, including 23/25-hour DST days, wall-clock day parts, weekdays, month/year boundaries and numeric rolling ranges. Separate cases cover quoted/smart-quoted operators, Unicode removal, URI form spaces/literal plus, typed parameter errors, fractional ISO export/import and embedded-NUL application-prefix rejection. Saved chat payloads remain backward readable. Current full-suite and sanitizer counts are recorded in the report. Earlier public relevance metrics remain unchanged in every mode on the authored 35-query fixture; no new natural-language generalization claim is made.

Own-app NSHosting renders verify minimum-size light/dark layouts. Native click/shortcut verification remains blocked by the locked Mac. No continuous capture, full competitor app runtime or 24-hour/power result is implied. Synthetic vector scans measure their documented storage/candidate path and exclude query-language resolution, embeddings and UI publication.

## Full-source semantic passage regression

```bash
python3 scripts/passage-smoke.py .build/release/oswindctl --provider apple --output .artifacts/passages-apple.json
python3 scripts/passage-smoke.py .build/release/oswindctl --provider ollama --require-recall --output .artifacts/passages-qwen.json
python3 scripts/passage-smoke.py .build/release/oswindctl --provider ollama --answer-provider ollama --output .artifacts/passages-answers.json
```

Three fictional long notes place distinct owner/deadline facts beyond 19,000 characters amid repeated background. The same store/model is queried first with only base vectors, then after passage backfill. An unrelated fourth record supplies a distractor. Measurements include separate CLI startup, model HTTP, query embedding, coverage and SQL scoring, so they are not comparable to in-process retrieval-only timings. Only three paraphrases are tested. There is no held-out dataset, cold-cache control, competitor or energy result.

Exploratory reports retain provenance limits. `passage-qwen-v2.json` is the release runtime at `acb52af`: base-only MRR .611 and passage MRR 1.0, with all selected passages containing the answer fact. Generation is separately **2/3**: two cited correct owner/deadline answers and one conservative abstention. The failed combined check is intentionally retained. The Apple precursor report reaches MRR .833 with one non-answer passage; full coverage does not establish semantic selection accuracy. Relevance/generation must be assessed independently.

The script also verifies real MCP passage metadata and that a CLI note remains committed with an offline optional model server. `--require-recall` fails on any selected semantic check (and on answer checks if generation was requested); without it, quality failures remain in the report while structural ingestion/MCP failures still fail the process.


The final runtime reports `passage-apple-v3.json` and `passage-qwen-v3.json` pin source `99c87c2`, binary/script hashes, raw source hashes and per-query ranks. The Qwen report retains the actual bounded evidence context: all three contexts contain the correct owner/day, yet generation abstains on one. The first two v1 reports are explicitly labeled exploratory precursors without a retained binary hash.

`metal-passages-1000000-v3.json` runs the upgraded parent-aware cache against the retained million-row archive, with 12 new queries in each scope (seed offset 10339). Recall@10 is 1.0/1.0 on these trials. Cache preparation takes 2.52 s, RSS peaks at 4.24 GB; self median/p95 is 27.36/96.77 ms unfiltered and 41.96/687.48 ms filtered. Non-self indexed p95 is 88.04/39.67 ms. The first exhaustive reference query takes 6.98 s; subsequent unfiltered references are about 1.1 s. These are uncontrolled cache trials and a small synthetic query set; parent grouping adds work and no energy or competitor claim follows. `passage-statistics-1000000.json` includes a 1.58 s open/new-index step, not a controlled full schema-5 migration timing.

Both failed recent-source SQL experiments are retained as `passage-slow-recent-v1.json` and `v2.json`. They were terminated before producing quantiles/recall. Process profiles showed SQLite work; the second plan scanned a global model/revision range per parent. The final code pins time/app-time and parent/revision indexes. A regression measures executed VM/full-scan steps on a 1,500-record store. Large timestamp tie groups and sparse arbitrary metadata scopes still need expanded workload tests.


## Full backup / restore with concurrent CLI work

`scripts/backup-benchmark.py` builds a private generated library, runs real release CLI create/inspect/restore under macOS `time -l`, keeps note writes and lexical searches running during creation, verifies the new library, then deletes the synthetic fixture. Source FK/integrity checks are required before measurement. Short note bulk rows have no vectors; concurrent CLI notes include Apple embeddings. The media are 1,000 padded one-pixel PNG files of 256 KiB each, not a realistic photo/audio distribution.

The initial `backup-100000-v1.json` trial is a **failed invalid fixture**: its Python template deletion had foreign keys disabled and left an orphan vector. Restore refused it without publishing. Its operation logs are retained. `backup-100000-v2.json` is the corrected passing trial: 100,016 snapshot records, 1,000 media files, 373,257,219 logical payload bytes; creation 6.487 s / 116,785,152 bytes peak RSS, inspection .695 s / 19,906,560 bytes, restore 25.931 s / 130,236,416 bytes. Forty-two concurrent CLI note/search cycles succeed; write median/max 54.21/67.00 ms, search median/max 45.14/53.89 ms, baseline search median 46.66 ms over five trials. CLI timings include process startup/store open. No improvement claim is justified by these uncontrolled, differently sized samples. Snapshot count is expected to precede later concurrent inserts.

These are single APFS operation trials with uncontrolled filesystem caches, CPU background work and short authored content. They do not establish a power budget, realistic 24-hour workload, million-vector restore, commercial-product ranking, non-APFS support or disk-failure durability. Unit/ThreadSanitizer, real SIGINT/SIGKILL/stale-lease recovery and rich one-source media/chat/vector/passage round trips supply separate correctness evidence. `scripts/backup-smoke.py --interruptions` uses a sparse 2 GiB synthetic asset to interrupt active hashing without recording personal content.


`scripts/backup-vector-benchmark.py` accepts only a retained fixture with OSwind's explicit synthetic-vector marker. `backup-vectors-1000000-v1.json` measures `db6aa03` on the existing million-record/1,024D fixture: 5,712,606,211 logical payload bytes, create 16.759 s / 116,310,016 bytes peak RSS, inspect 2.666 s / 19,251,200 bytes, restore 184.396 s / 199,278,592 bytes. One million source rows (JSON values plus SQL fields/legacy embedding) and one million supplemental vector/hash rows match afterward in bounded 64-row batches; full SQLite integrity/FK checks pass. That fixture has no media/chats. Native graph files are excluded and restore derives fresh registry/counters/identity. Uncontrolled cache state and unit/TSan work overlapping later restoration prevent an isolated-throughput claim; power and competitor comparisons remain open.

`backup-quiet-retention-v1.json` records a 330.9-second paused demo app run: six old January-2000 sources survive the five-minute housekeeping timer with restored automatic cleanup off and a one-day retention limit. `backup-process-v1.json` records real release SIGINT/SIGKILL recovery and media/chat reuse. These are separate correctness checks, not continuous recording or native panel acceptance.

## Native speech component: synthetic speaker consistency

`speech-diarization-synthetic-v1.json` records an isolated FluidAudio 0.17.7 / Community-1 offline trial, not app integration. Four original scripted utterances use stock Kokoro `af_heart` / `am_echo` in A/B/A/B order, with .75-second gaps (32.225 s total). The model chooses two clusters automatically and maps all four utterances consistently; all 76 eligible ASR-timed words (excluding .25 s around utterance edges) associate with their known synthetic voice cluster. Parakeet v3 transcribes the 80 scripted words with normalized WER 0 in this same easy clean fixture. Its reported inference is .173 s; diarization processing is 3.062 s. First diarization process is 16.18 s including 12.738 s model loading/download/compilation. Peak RSS is 204,259,328 bytes; macOS reports a larger 491,340,856-byte peak memory footprint, so RSS alone understates total memory impact.

The reference uses known generated voice sources and clip intervals, not independently annotated natural speech activity; ASR word times are not independent annotations either. These checks establish synthetic association/consistency and execution, not natural-meeting DER/WDER, noise/overlap quality, energy, speaker identity or a competitor rank. The standalone pinned `tools/SpeechProbe` and its local fixture generator make the method reviewable. Code and model licenses are separate: SDK Apache-2.0, supported Community-1 converted assets scoped CC BY 4.0 per upstream card/NOTICE/provenance. Further model setup/integration and capture-lifecycle testing remain ahead.


## Integrated speech import (JFK, v1)

`benchmarks/speech-import-jfk-v1.json` records eight release CLI imports, two per configuration, on Apple M5 Max. Every trial normalizes the public 11-second JFK recording, recognizes, sanitizes, inserts and retrieves its transcript in a fresh library/process. All have normalized WER 0 on this one clean known clip. Parakeet returns 22 word spans; Whisper base.en returns one segment. This is a functional/latency regression, not held-out speech accuracy, independent word-alignment scoring or a competitor app comparison.

| Configuration | First trial wall | Second trial wall | Reported peak RSS range |
| --- | ---: | ---: | ---: |
| Parakeet / ANE+CPU | 10.986 s | .254 s | 103–532 MB |
| Parakeet / GPU+CPU | 6.598 s | .509 s | 2,419–2,636 MB |
| Parakeet / CPU | 1.770 s | .379 s | 1,347–1,711 MB |
| Whisper base.en / default | 13.653 s | .304 s | 385–411 MB |

Existing Core ML/weight caches and system background activity are uncontrolled. “First” does not mean a reproducibly cold machine, and these numbers do not measure resident throughput or energy. RSS/footprint accounting differs and may exclude external ANE/Core ML services; these are not whole-system memory totals. Do not infer a universal engine/compute winner from two short trials. Raw outputs, file hashes, source/binary identity, retrieval checks and limitations are retained.

```bash
python3 scripts/setup-native-speech.py --destination /absolute/new/model-directory
python3 scripts/speech-eval.py .build/release/oswindctl \
  --audio /absolute/public/jfk.wav \
  --reference "And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country." \
  --native-model /absolute/new/model-directory \
  --whisper-model /absolute/ggml-base.en.bin \
  --output /absolute/speech-import-report.json
```


## Integrated imported speaker workflow (synthetic, v1)

`speaker-import-synthetic-v1.json` runs the real packaged CLI through snapshot/normalization, local Parakeet + Community-1 inference, redaction/admission, naming, lookup, retained-byte comparison, full backup/restore, text interchange and deletion. It includes all 80 raw word assignments, authored stock-voice utterance intervals, model/catalog/binary identity and unknown counts. Voice embeddings are not exported.

Four stock-voice A/B/A/B utterances (32.225 s) yield two recording-local clusters and normalized ASR WER 0. Among 76 ASR-midpoint words at least .25 s from an authored utterance edge, 71 have the expected synthetic voice label, five are unknown and none have the other voice's label. Nine of all 80 words are unknown. Reporting only correctness among assigned words would conceal the abstentions. The raw report retains whole-import wall time, which includes loading/compilation/saving with uncontrolled caches. It is not resident inference throughput or measured energy.

This is a clean generated-voice regression. Known source-voice intervals plus model-generated word times are not independent word alignment, natural-meeting DER/WDER, overlap/noise robustness, live/cross-recording voice identity or a competitor ranking. Product UI rendering/compilation does not prove native click/keyboard or device acceptance.

```bash
python3 scripts/setup-native-speech.py --model speakers --destination /absolute/new/community1
python3 scripts/speaker-smoke.py dist/OSwind.app/Contents/MacOS/oswindctl \
  --fixture /absolute/generated-two-speaker-fixture \
  --asr-model /absolute/parakeet-v3 --speaker-model /absolute/new/community1 \
  --output /absolute/speaker-product-report.json
```


## Native model streaming and interruption checks

`native-model-install-v1.json` records real fresh native Swift downloads and offline verified reuse for Parakeet (483,106,120 bytes / 22 files) and Community-1 (21,816,863 bytes / 28 files). The development CLI reports 40.6 MB and 45.3 MB peak RSS respectively; transfers take 47.78 s and 17.32 s on an uncontrolled network/CDN. This tests disk streaming rather than buffering a model-sized response; it is not a final-release timing baseline, inference/energy measurement or competitor ranking. The exact development binary and streaming source hashes are retained, with source-state limitations.

The release CLI also survives graceful SIGINT after real streamed bytes (exit 130, private staging removed). A SIGKILL leaves a recognized dead lease; the next install removes it and verifies an APFS-cloned complete pinned model without redownloading it. This establishes orphan recovery, not partial-byte resume. Native-model listing/verification/downloads do not create a normal memory library. A separate explicit-cache app integration test verifies the real installed weights and applies both choices without starting capture.

```bash
python3 scripts/native-model-smoke.py .build/release/oswindctl \
  --installed-model /absolute/verified/parakeet-v3-7dd20fe6b179 \
  --output /absolute/native-model-recovery.json
```


## Recording-local speaker answers

[`speaker-evidence-synthetic-v1.json`](speaker-evidence-synthetic-v1.json) records the packaged release CLI on the 32.225-second stock-voice A/B/A/B fixture. Real Parakeet and Community-1 produce the transcript; two recording-local labels are manually named Maya/Theo. Names are absent from raw transcript text but are found through the name index and exact speaker scopes. Speaker-tagged literal evidence aligns to the original transcript; unknown spans remain unknown.

Qwen3 4B Instruct returned the expected attribution/content with source `[1]` on all five supported authored questions and abstained on an invented budget question. Every answer, warning, citation index and authored string expectation is retained. These are six transparent questions from one clean generated clip, inspected by the coding agent, not a held-out/natural-meeting accuracy score. An earlier pre-clarification run returned the right name with invalid citation `[8]`; that failure is also recorded. Header/prompt clarification fixed this observed case, without establishing universal citation correctness.

The release import took 0.895 s in one warm/uncontrolled-cache trial, including normalization, native ASR/diarization, privacy, persistence and indexing. Ollama reported its 3,311,423,979-byte allocation fully in GPU memory, with context 8192. This does not profile every operation, whole-system memory, energy or competitor performance. Exact binary/source-file hashes, model digest and limits accompany the responses.

```bash
python3 scripts/speaker-evidence-smoke.py dist/OSwind.app/Contents/MacOS/oswindctl \
  --fixture .artifacts/diarization-fixture \
  --asr-model /path/to/parakeet-v3 --speaker-model /path/to/community1 \
  --chat-model qwen3:4b-instruct-2507-q4_K_M --output /tmp/speaker-evidence.json
python3 scripts/speaker-search-smoke.py dist/OSwind.app/Contents/MacOS/oswindctl
```

Generate the fixture with `tools/SpeechProbe/make-fixture.py`. The second script needs no model downloads and tests deterministic metadata through actual CLI, HTTP and MCP processes; it runs in CI. Neither script opens the normal capture library or exercises native input/device acceptance.


## Long-transcript search materialization

[`audio-search-preview-v1.json`](audio-search-preview-v1.json) compares complete versus explicit preview results using the same release binary and synthetic archive: **32 recordings × 10,000 timed segments**. Three fresh processes per mode each run seven keyword queries; process order alternates. The medians of those process trials were:

| Measurement | Complete results | Preview results |
|---|---:|---:|
| Query p50 | 371.188 ms | 25.018 ms |
| Query p95 | 389.665 ms | 26.964 ms |
| Process query peak RSS | 104.53 MB | 29.46 MB |
| JSON response | 30.115 MB | 3.184 MB |
| Response encoding | 358.4 ms | 6.1 ms |
| One selected source hydration | 34.7 ms | 23.3 ms |

Ordered source IDs/ranking and complete raw text match. Full mode returns all timed segments; preview mode explicitly reports their omission, counts and revision. Opening one result revalidates and restores all timings. Query RSS is sampled before response serialization and source hydration; both later stages are separately reported. Each query retains the previous result list while the next is loaded, as the app does during publication.

This fixture measured about **14.8× faster median query time** and **3.5× lower process query peak RSS**. It does not establish general UI responsiveness, arbitrary-length memory bounds, natural relevance, model inference speed, tag-filter latency, power or competitor ranking. Raw text remains in previews. File/OS caches and background activity are uncontrolled; fresh processes are not controlled cold-cache trials. The 1.399-second preparation includes generation, validation, hashing, writes and per-clip preview verification; it is not ingestion-only throughput. The derived preview payloads add 3.182 MB of serialized text/metadata to the stored source data; they trade storage for lower query decoding cost.

```bash
python3 scripts/audio-search-benchmark.py dist/OSwind.app/Contents/MacOS/oswindctl \
  --clips 32 --words 10000 --trials 3 --repetitions 7 \
  --output /tmp/audio-search-preview.json
python3 scripts/search-preview-smoke.py dist/OSwind.app/Contents/MacOS/oswindctl
```

The benchmark command refuses unmarked existing data and constructs only an explicitly new synthetic archive. The process smoke verifies complete defaults, explicit previews, full-source reads, invalid-detail handling, rename revision updates, preview-import rejection and rebuilt backup caches without model downloads. Raw process measurements, identities, source/binary hashes, hardware and all scope limitations are retained in the report.

The packaged [native answer regression](audio-search-native-regression-v1.json) repeats the actual local ASR/diarization and six authored Qwen questions after preview retrieval/full-source hydration. Five supported outputs cite `[1]` correctly; the invented budget question abstains. Full transcripts, evidence, model responses and hashes are retained. This remains one synthetic recording, not independent natural-meeting validation.


## Sampled visual replay

[`visual-replay-v1.json`](visual-replay-v1.json) records three packaged release probes on code `dd2f372`: 12 generated 1280×720 frames, actual Vision OCR, required-hardware HEVC, every-frame decode and strict authored frame-token/ownership OCR checks before and after encoding. All 36 frames pass. Each trial uses 59,969 video bytes plus 31,236 thumbnail bytes versus 572,784 quality-0.75 JPEG reference bytes: ratio 0.159. The fixture is static desktop-like content with changing labels. This excludes metadata/database bytes, daily storage, power, capture throughput and competitor apps. A retained heading OCR “0”/“O” diagnostic and the current exact-token criterion are described in the report.

[`visual-replay-native-v1.json`](visual-replay-native-v1.json) separately records a 12-second parent-build synthetic-window stream (12 frames/four HEVC clips), full movie decoding, final release-player opening, earlier pilot controls, locked admission and pending latest-device checks. [`visual-replay-regression-v1.json`](visual-replay-regression-v1.json) records 329 tests (325 pass/four opt-in skips), 60 sanitizer cases and release process contracts. These scopes establish no full replay/power/competitor acceptance. See [replay reproduction and remaining gates](../docs/REPLAY.md).


## Natural speech and overlapping speakers

[`speaker-natural-overlap-v1.json`](speaker-natural-overlap-v1.json) retains paired results for ten predetermined VoxConverse development clips, in two fixed five-clip groups. The product's former exclusive output trimmed overlapping voices before mixed-word attribution. Preserving overlap reduces no-collar DER from **12.03% to 9.78%** in the first group and **8.52% to 7.66%** in the second. With a 250 ms collar, the pairs are **9.42% → 7.36%** and **6.87% → 5.98%**, including overlap. The report retains regressions and speaker-count errors; this is not an official held-out/full-corpus or competitor-app ranking.

An actual public-file product import also preserves 2,606 Parakeet timed segments through persistence and backup. All 175 word spans intersecting model-predicted mixed speech above the attribution threshold remain unassigned. This is a pipeline-safeguard check, not human word-speaker accuracy or ASR WER. [Reproduction, licensing and scope](../docs/SPEAKER-EVAL.md) and the retained [pre-fix baseline](speaker-natural-baseline-v1.json) separate these claims.

- [Signed package natural-speech regression](speaker-natural-packaged-v1.json): exact shipped binary, identical development-subset scores, real silence and private-output contracts; full limits in [SPEAKER-EVAL](../docs/SPEAKER-EVAL.md).

- [Native model idle retention](native-model-idle-v1.json): actual 120-second timer/reload, queue/policy/controller contracts and signed-package process identity; no RAM reclamation or power claim.

- [Scheduled routines](routines-v1.json): atomic claims, native real-clock timer/local Qwen result, actual source navigation and deterministic cancellation; signed installed process/backup/erasure contracts. Full limits in [ROUTINES](../docs/ROUTINES.md).

- [Complete development speaker comparison](speaker-corpus-v1.json): 216 recordings / 20.30 hours, two runs/policy, independent full-WAV/overlap-inclusive DER; all regressions and repeat differences retained. This is development evidence, not official test or competitor quality.

## Portable Markdown export and native replay follow-up

[Markdown export validation](markdown-export-v1.json) covers every source/turn beyond display limits, literal content, current privacy and dependent-turn suppression, optional-media byte identity, snapshot isolation, no-overwrite paths, cancellation and killed-job cleanup. Native QA on an isolated 20,004-source library verified the actual save panel, progress, disabled library transfers, Cancel and completion; all 40,016 relative links resolve and eight media files match their originals. The earlier UI that wrote output without showing completion is retained as a failure before the observed-child-view fix. [Usage, reproduction and limits](../docs/EXPORT.md).

Two generated English-text sizes expose a retained memory regression: 2k/20k records initially peaked at 229.84/2086.44 MiB. Per-record/turn Foundation autorelease pools plus removing an unused CLI embedding-model load reduced these single-run peaks to 49.42/107.33 MiB; wall times 1.58/15.54 s. These are combined changes, not an attribution experiment. All record identities passed. No realistic archive, constant-memory, natural media, competitor or energy claim follows. The independent CommonMark renderer enabled raw HTML and still found no active remote images/scripts/iframes/URLs in the authored adversarial source and metadata fixture; YAML title/alias/tag values round-tripped.

[Replay v2](visual-replay-native-v2.json) closes the earlier locked-device native gate on descendant `dffc180` with unchanged replay UI source: correct Frame 21 on open, aligned letterbox boxes, seek, play/pause/stable clock, final Frame 23 at 5.002 s and restart. Broader natural capture, lock recovery, global shortcut/focus, all-display replay and power gates remain open.

## Required content expressions

[Search expressions](search-expressions-v1.json) records required quoted phrases and uppercase Boolean source conditions before keyword/vector ranking, literal bypass, speaker labels, current-question Ask constraints, typed errors and snapshot cleanup. The 20k/32D Metal trial matches exhaustive float32 top-10 when switching phrases and after a deliberately unreplayed content edit. An initial uncommitted worktree diagnostic took 2.16–2.66 s because FTS eligibility was recomputed for native candidates. Materializing IDs once reduced three debug measurements to 46–57 ms; these are not release latency percentiles or a competitor/power comparison.

The 32-document/35-query regression retains every aggregate quality component for Apple and local Qwen in keyword/hybrid/semantic modes. Qwen's authored-fixture Recall/MRR remain 1.0; the known absent-evidence candidate weakness remains. Actual local Qwen conversation answers the owner/deadline with citations and preserves reopening/erasure. [Semantics, limits and reproduction](../docs/SEARCH-EXPRESSIONS.md). Native input/help/keyboard acceptance remains distinct from the inspected light/dark sample renders.


## Selective history erasure

[Erasure v1](history-erasure-v1.json) records half-open source-overlap and exact app/bundle/site/type intersections, library/source/dependency-bound previews, transactional source deletion plus durable media cleanup, canonical shared-file protection and actual SQL cancellation. A retained dot/case-path regression removed a shared file before the fix. Final tests: 398 pass / six opt-in skips, 31 focused TSan pass; eight CLI writers with one preview produce exactly one commit. Final signed installed CLI contracts pass. The earlier release also passed full backup/restore/interruption and required-search CLI/HTTP/MCP/Ask regression checks.

The generated 20k-source/10k-media release trial accounts for all shared files in the first half and removes every unique file in the remainder. Per-operation wall/peak RSS are in the report; FTS identifier scans remain a bulk-delete scaling follow-up. Single cached synthetic trials with concurrent background activity do not establish natural archive, power, durability or competitor performance. [Semantics and limits](../docs/HISTORY-ERASURE.md) distinguish live logical deletion from external copies, earlier independent saved recaps and secure SSD erasure. Native clicks/confirmation/focus remain pending while locked.


## Direct FTS source maintenance

[FTS maintenance](fts-maintenance-v1.json) replaces per-source unindexed identifier scans with explicit stable integer keys. Same 20k-source/10k-media release workload: earlier 17.43/8.77 s for the two erasure halves; current trials 2.89/4.09 and 2.82/4.35 s. CLI peaks remain about 31 MiB. All trials are retained; the second independently verifies every surviving source ID, media filename and shared-file byte string outside timed operations. These are generated cached trials with concurrent activity, not general latency/energy/competitor evidence. Baseline bulk checks were counts plus small process byte-identity tests.

410 tests (404 pass / six opt-in skips), 37 focused TSan pass; actual previous schema-13 writer insert/upsert/delete, cache migration/no-repeat/trigger repair, deliberate source-rowid renumber/VACUUM and installed erasure/backup/interruption/search contracts pass. Apple/Qwen authored quality aggregates are unchanged. [Implementation/reproduction/limits](../docs/FTS-MAINTENANCE.md). Whole v0, natural capture/power, native interaction and independent relevance/competitor gates remain open.


## Shared-media individual deletion and retention

[Unified deletion](unified-deletion-v1.json), schema14 code `8d45d11`, records the retained individual/time-retention shared-file failures and the universal transactional queue fix. Canonical aliases, pending retry, detailed committed outcomes, async native status, strict metadata-only CLI commands, oldest-first bounded storage cleanup and cancellation after 16 committed removals are exercised. Full 425: 419 pass / six opt-in skips; focused 57 TSan pass before copy-only label correction, then final exact-copy full suite passes. Real prior-version refusal preserves database bytes after 13→14 upgrade.

The generated age-retention release trial covers 20k sources/10k tiny shared files: 2.29/3.41 s for the two halves, about 29 MiB CLI peak. Every remaining source ID, media filename and shared-file byte string passes independent checks. This is not a large storage-budget, natural media/vector, power, percentile or competitor benchmark. Installed single/retention/queue, full backup/interruption, selective-erasure/eight-writer, query/Ask, routine and actual local Qwen chat regressions pass. [Semantics, reproduction and remaining gates](../docs/DELETION.md) preserve the limits around index rebuild fallback, per-operation reference scans, independent recap copies and already-open older processes. Native clicks remain pending while locked.
