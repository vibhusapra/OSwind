# Native index construction and cache admission

The pinned native graph can store every vector while leaving some vectors unreachable from search. Native insertion is now serialized, and the native cache generation changes from `passages-v2` to `serial-passages-v3`. Old native caches rebuild from original SQLite vectors when indexing prepares. Metal's existing batching and format stay unchanged.

## Reproduced failure

The preceding portable-records qualification failed the existing exact-versus-indexed scope test: row-134 was missing from the indexed top five. That particular graph was removed by test teardown. Its exact cause cannot be reconstructed from the retained log, and the original graph has not been recovered.

An opt-in probe now captures the actual authored fixture, live graph, original Float32 vectors, query results and native membership before teardown. It does not change the original ranking assertion, native options, source rows or cache. Output requires an explicit private directory and ownership marker; it never searches temporary directories or normal desktop history.

The first captured graph has 256 members, all present and readable through native contains/get. Unfiltered searches with a budget of 2,000 return only 248. All 256 original source vectors, used separately as queries, enumerate the same 248 members; loading the saved graph reproduces the omissions. Stored values are finite Float16 approximations of the original vectors. This establishes a reachability problem rather than absent source records.

A direct control using the same authored vectors returns all 256 with serial insertion, 255 with two concurrent workers and 250 with four concurrent workers. A retained old graph is also injected through the application's real cache loader with the correct identity, sequence, format and checksum. Its exact top five begins with row-114 and row-119; the admitted old cache omits both. The new generation rebuilds and matches exact retrieval. Original canonical frames and retained graph bytes remain unchanged.

These are reproducible instances of the same omission class. They do not establish the precise native race or prove what happened inside the unavailable historical row-134 graph. No upstream dependency change is claimed.

## Behavior and regression coverage

- Native batch thread counts remain hints; native insertion always uses one worker. Cache ownership already serializes external calls.
- A new format changes both the cache prefix and admission checks. A checksum alone cannot distinguish a graph with unreachable members.
- The generated regression graph and its provenance are test resources only. The packaged application does not include the test bundle.
- Four integrity cases cover direct full-budget enumeration, real legacy-cache admission, four replacement/replay rounds with either thread hint, and paged append through 1,024 members.
- The original five-scope exact-ranking assertion and `ann-exact-rerank` strategy assertion stay intact. Diagnostics are optional locally and retained by CI, including on failure.

## Native preparation measurements

On this Apple M5 Max / 128 GiB Mac, three sequential optimized repetitions per size used identical authored 512-dimensional vector bytes before and after the policy change. The table reports medians for the former four-worker request and the same request under the new serial policy.

| Members | Former parallel preparation | Serial preparation | Ratio |
| --- | ---: | ---: | ---: |
| 1,000 | 0.0349 s | 0.1276 s | 3.66× |
| 5,000 | 0.4028 s | 1.4992 s | 3.72× |
| 10,000 | 1.2297 s | 4.5751 s | 3.72× |

Preparation includes native initialization, reserve, page arrays and insertion. Source generation, SQLite ingestion, embedding/model work, quality probes and graph saving are outside the timer. The former 1,000-member parallel trials miss three of 384 sampled self queries; the new policy misses none at each size. Zero sampled misses at larger sizes does not prove complete connectivity or representative relevance. Whole-process peak memory across sequential trials is not a controlled per-policy memory comparison. These are component observations, not app ingestion, energy or competitor rankings.

Correct construction currently costs speed. Further work must preserve the retained bad-graph regression and demonstrate both recall and throughput before restoring parallel native construction. The Metal path remains separately qualified by its existing tests.

## Qualification and remaining work

The focused development selection passes 51 cases. Frozen broad qualification passes all 14 stages over 839 unchanged inputs: 1,446 full passes / eight explicit skips, and 251 sanitizer and 251 optimized passes / two worker-entry skips each. All four integrity cases, the original indexed-retrieval class, all 24 portable-record cases and all four identity crash parents pass. Thread Sanitizer reports no race warnings.

Thirty-two optimized scoped replays pass and each retains its actual source snapshot and live graph. Independent review regenerates original Float32 source bits, checks canonical frames and stored native vectors, and verifies full reachability plus exact agreement in all five scopes for all 34 captured graphs built with the fix. Three historical captures preserve the old omissions. Six historical source/test input versions and the retained pre-policy binary/resource bytes remain available; the original row-134 instance remains unavailable.

Staged capture, conversation, recap, deletion, wipe, backup/interruption, normal/indexed HTTP/MCP and offline SDK checks pass. Independent strict signatures, normalized executable payloads and all 34 extracted ZIP files agree. The authored test-resource bundle is absent from the app; all five traced owned images are absent. The installed 15-file application remains unchanged. These are staged component/package checks; notarized distribution and native release acceptance remain open.

The [receipt](../benchmarks/native-ann-integrity-v1.json) also records 256 non-self query comparisons: 64 query seeds, two scopes and two archive sizes (1,000 / 10,000 members × 512 dimensions). All indexed top tens agree with exact retrieval. An independent NumPy reader regenerates every original source-vector bit, validates all authored source rows and recomputes every exact top ten using Float64 cosine. Original database and WAL bytes remain unchanged during that review. This is synthetic quality evidence, not language relevance or exhaustive large-graph connectivity.

The first quality reader incorrectly treated SQLite shared-memory bookkeeping as immutable source. Its failed hash assertion and original reader remain retained. The exact first hash delta was not persisted, so its specific cause is not proven; a subsequent unchanged read cannot reconstruct it. The follow-up compares database/WAL bytes explicitly and retains their before/after hashes. Product code, authored vectors and quality thresholds stay unchanged. Initial test compilation and pre-fix native/cache assertion failures also remain in the receipt.

The [delivery ledger](PROGRESS.md) and [feature landscape](landscape.html) retain the full scope. Full personal sync, physical power evidence, notarized distribution and native release acceptance remain open. This index correction does not establish feature-complete parity or a top-three ranking.

To retain the authored test probe locally:

```sh
python3 scripts/prepare-owned-index-probe.py /absolute/new/private-output
OSWIND_TEST_INDEXED_RETRIEVAL_OUTPUT=/absolute/new/private-output swift test --filter 'IndexedRetrievalTests|NativeANNIntegrityTests'
```

The parent of the new directory must already exist, and the path must be absolute and free of symlinks. The preparation command refuses an existing destination. Native-only measurements additionally require `OSWIND_TEST_NATIVE_BUILD_MEASUREMENTS=1` and the `NativeANNBuildMeasurementsTests` filter.
