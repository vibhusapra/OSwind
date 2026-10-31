# Phrase and Boolean query scaling

Qualified for the bounded workload below. The preceding [capture qualification](SYNC-CHANGE-CAPTURE.md) measures about 3.1 seconds for a broad required-phrase query over one million authored sources. This work removes unnecessary archive-wide eligibility construction from keyword retrieval and empty-model fallback. It is not a complete search-quality, semantic-scale, energy or competitor qualification.

## Behavior and invariants

The expression parser and ranking operands stay intact. Phrases remain required; unquoted words remain soft ranking cues; explicit Boolean precedence, negation, prefixes, cross-field body/speaker matches and metadata/time scopes remain enforced before the result limit. The query does not take a fixed top-K pool and discard ineligible records afterward.

Each ranked source checks content atoms against its stable `memory_fts_keys` key. It does not use the source table's implicit rowid, which can change during maintenance. Speaker operands retain their per-atom source sets, so separate labels or body text may satisfy separate parts of an expression. Speaker-heavy archives can still incur substantial set work; this is a remaining measurement requirement.

An actual semantic stage still materializes its full eligible set for vector scans and native masks. That work now happens after lexical retrieval and only when the selected model has vectors. The existence check reads the actual legacy, extra-vector and passage tables inside the search snapshot; a caller's stale coverage hint cannot hide another connection's committed vectors. Semantic searches with vectors retain their existing eligibility/mask path.

Before ranking, indexed necessary checks can prove an application, kind, favorite, tag, entity, speaker or time scope empty. These checks run in the current snapshot and keep no empty-answer cache. They do not replace the complete combined metadata/content predicate. A later committed matching source remains visible on the next query.

SQLite cancellation handling now covers lexical statements too. The handler is removed before cleanup. Only a scope that was actually materialized needs clearing. No schema/version, original source format, source mutation, public sync control or provider permission is introduced.

## Development evidence

- A read-only Python SQLite 3.54.1 diagnostic over the already authored million-source archive measures roughly 3.09 s constructing the temporary source-ID set, 0.70 s ranking with it and 0.50 s using candidate-local checks. The ordered top 100 agree in that diagnostic. These SQL-only, sequential, uncontrolled-cache observations use a different runtime from the product and are not release performance results.
- A test-fixture argument-order compilation error is retained; no tests ran in that attempt. The corrected first selection passes 52 cases with one explicit Metal opt-in skip.
- The expanded development selection passes all 63 cases. The actual 20k-vector Metal phrase workload executes, with exact top-ten agreement on its three queries. New cases cover high-ranked ineligible soft matches before a required hit, stable keys after source rowid changes and VACUUM, NUL-containing internal IDs, Unicode speaker renaming, mixed speaker/body Boolean rules, vectorless/empty-model fallback, stale coverage hints and cancellation recovery.
- The paired CLI fixture passes 36 keyword/local-hybrid observations against the preceding signed 793574e binary. Ordered hits, scores, complete returned sources, match/passage and warnings/model/strategy agree. Explicit keyword memberships and six invalid-syntax refusals are checked; original payload hashes remain unchanged. The first fixture was refused by the baseline public importer's existing NUL-ID guard; that failed setup remains retained. The public fixture now uses a normal ID, while the direct MemoryStore unit test retains NUL coverage.
- Five offline benchmark-admission contracts cover result identity/order/score/source changes, invalid results/timings, quantile definitions and unmarked/incomplete archives.

The first signed development pairing at source 33bf9b7 passes all 64 responses per size at 100k and 1m, with three timed rounds plus warmups. At 1m, required-phrase median reported search time is 2679→1209 ms and empty-model hybrid 3060→1301 ms; rare lookups remain around 1.5–1.7 ms. Empty application scope still takes 3824→2169 ms, motivating the subsequent indexed empty-scope checks. These preflight results remain separate from the final frozen measurements.

A second read-only diagnostic uses the actual system SQLite 3.51.0: stable-key and direct ranked-rowid checks take 1233/1239 ms with the same 100 results. Direct rowid substitution is therefore not pursued. The Python SQLite 3.54.1 diagnostic cannot be used as a product speed claim. Separate review of all 1k/100k/1m preflight responses verifies authored ordering, RRF scores, complete paired responses/scopes, original typed rows/payloads, response hashes and timing quantiles. The updated development selection passes all 86 cases, including impossible metadata scopes, later cross-connection insertion, text-observation time scopes and the 20k Metal workload.

## Paired release protocol

`scripts/benchmark-keyword-scope.py` accepts only the completed, marked authored scale archive. It validates every original row and payload before cloning; each profile receives a separate APFS database clone. The retained input database and executable hashes must remain unchanged. No normal desktop history or live capture is opened.

The same query cases run in alternating baseline/candidate order, after one warmup per case/profile. Cases include broad phrases, Boolean exclusion, a rare soft cue, application scope, rare phrase/prefix, empty scope and local hybrid with no indexed model. Exact signatures include ordered results, scores, complete returned sources, match/passage, warnings/model/strategy and resolved scope; elapsed time is the only omitted result field. Independently checked source membership, explicit exclusions, rare first hits and empty scopes prevent result truncation from looking like an improvement.

The report retains every actual CLI response and raw timing. CLI process wall time and the product's reported search duration are separate. Median averages the center pair and p95 uses nearest rank. Small, warm same-device samples and uncontrolled filesystem caches/background activity do not establish a population tail, cold-cache behavior, capture/ingestion throughput, GPU efficiency, physical energy or ranking against another product.

The frozen checks below complete the matched optimized measurements, independent source/result/timing review and broad package/process regression. Broader semantic and speaker-heavy scale, capture quality, sustained power and complete user-facing sync remain open.

## Frozen signed qualification — source 7e0d88a

[PR #95 receipt](../benchmarks/keyword-scope-scale-v1.json) retains all 40 passing stages across 819 unchanged inputs. The [raw response bundle](../benchmarks/keyword-scope-raw-v1.zip) contains all 288 actual scale response JSON files and stderr files, plus the two small query-contract receipts. Every member hash is retained.

| Check | Result |
| --- | --- |
| Full suite | 1,386 defined; 1,381 pass; 5 explicit skips; zero failures |
| Thread Sanitizer | 405 pass; 2 skips; zero failures or race warnings |
| Optimized selection | 405 pass; 2 skips; zero failures |
| New keyword constraints, each build | Four cases pass; lexical cancellation recovery and actual 20k-vector Metal phrase test pass |
| Paired query contracts | 36 actual old/current comparisons; complete ordered hits/scores/sources/warnings agree; six invalid-syntax refusals; original payload hashes unchanged |
| CI control | Separate current/current fixture passes and explicitly declares sameBinaryControl; it is not an older-release comparison |
| Scale | 1k/100k/1m; 96 actual responses per size; five timed rounds per case/profile plus warmup; all source and independent result/timing oracles pass |
| Other boundaries | Signed CLI, HTTP, MCP, Python SDK, privacy, older-client refusal, deletion, wipe, backup/restore and interruption groups pass |
| Package / cleanup | Strict signatures and extracted ZIP/payload equality pass; 11 traced images independently absent; installed 15-file app unchanged |

The five full-suite skips are the opt-in native system-audio fixture, two subprocess worker entry points, the separately executed scale entry point, and the session/thermal wake callback gate. Both crash parents execute. The two selected-build skips are worker entry points. Exact skip names are retained in the receipt.

Source-specific hosted CI passes both jobs in [run 41162173908](https://github.com/vibhusapra/OSwind/actions/runs/41162173908). The parent cc6762e run fails its cancelled native vault-lock case with normal detach exit 16; that failure is retained, and its cause remains unproven. This passing run does not resolve it. Publication-head CI is separate.

### Matched warm observations

| Sources | Query | Prior / current median search | Prior / current p95 search |
| --- | --- | --- | --- |
| 1,000 | required | 4.078 ms / 3.374 ms | 4.080 ms / 3.521 ms |
| 1,000 | boolean | 4.077 ms / 3.467 ms | 4.121 ms / 3.682 ms |
| 1,000 | soft-cue | 4.119 ms / 3.496 ms | 4.218 ms / 3.549 ms |
| 1,000 | scoped | 4.139 ms / 3.431 ms | 4.214 ms / 3.464 ms |
| 1,000 | rare-phrase | 1.829 ms / 1.707 ms | 1.877 ms / 1.778 ms |
| 1,000 | rare-prefix | 1.627 ms / 1.651 ms | 1.659 ms / 1.700 ms |
| 1,000 | empty-scope | 3.835 ms / 1.484 ms | 3.871 ms / 1.532 ms |
| 1,000 | hybrid-empty-model | 7.032 ms / 6.100 ms | 7.093 ms / 6.223 ms |
| 100,000 | required | 225.202 ms / 137.317 ms | 227.189 ms / 138.656 ms |
| 100,000 | boolean | 225.366 ms / 121.792 ms | 241.355 ms / 123.697 ms |
| 100,000 | soft-cue | 226.645 ms / 137.258 ms | 230.520 ms / 138.189 ms |
| 100,000 | scoped | 225.263 ms / 135.449 ms | 226.323 ms / 138.010 ms |
| 100,000 | rare-phrase | 1.781 ms / 1.749 ms | 1.868 ms / 1.808 ms |
| 100,000 | rare-prefix | 1.694 ms / 1.696 ms | 1.796 ms / 1.751 ms |
| 100,000 | empty-scope | 328.841 ms / 1.498 ms | 334.502 ms / 1.515 ms |
| 100,000 | hybrid-empty-model | 257.658 ms / 137.425 ms | 260.467 ms / 143.508 ms |
| 1,000,000 | required | 2774.312 ms / 1241.501 ms | 2802.451 ms / 1249.521 ms |
| 1,000,000 | boolean | 2738.191 ms / 1108.840 ms | 2745.927 ms / 1121.400 ms |
| 1,000,000 | soft-cue | 2802.500 ms / 1245.724 ms | 2829.335 ms / 1256.273 ms |
| 1,000,000 | scoped | 2765.271 ms / 1231.887 ms | 2792.788 ms / 1235.042 ms |
| 1,000,000 | rare-phrase | 1.662 ms / 1.612 ms | 1.738 ms / 1.652 ms |
| 1,000,000 | rare-prefix | 1.545 ms / 1.553 ms | 1.551 ms / 1.643 ms |
| 1,000,000 | empty-scope | 3859.046 ms / 1.427 ms | 3871.209 ms / 1.465 ms |
| 1,000,000 | hybrid-empty-model | 3054.111 ms / 1309.063 ms | 3072.808 ms / 1322.294 ms |

Reported search duration excludes process startup. The receipt separately retains CLI wall durations and every raw observation. Five samples do not establish a stable population p95; filesystem caches and background activity are uncontrolled. Exact result parity is checked for all warmups and timed rounds, including the empty scope and rare soft cue. The archive has authored note text and no indexed model, so the hybrid row tests empty-model fallback rather than neural inference. No rows are discarded after an unfiltered fixed top-K limit. The optimized metadata checks are necessary conditions; full combined eligibility remains in the ranking query.

All original typed source rows and exact payloads are hashed before and after both cloned profiles; the retained input databases remain byte-identical. Independent review verifies actual returned fields and RRF scores, response/stderr hashes and recomputes quantiles. It does not independently instrument the harness wall clock. Historical preflight and setup failures remain separate from this final source. Hosted source and publication-head CI are recorded separately from local qualification.

Remaining work: broad semantic and speaker-heavy archives, representative relevance and answer abstention, sustained capture/power, complete sync and distribution. These results do not replace the stock Screenpipe comparison or establish product ranking.

## Primary reference

[SQLite FTS5 ranking](https://www.sqlite.org/fts5.html#sorting_by_auxiliary_function_results) documents sorting through the hidden rank column. The product retains its existing weighted BM25 rank mapping and ordering; this change concerns eligibility work around that ranking path.

[Report publication QA](../benchmarks/keyword-scope-report-qa-v1.json) reopens all bundled responses, verifies every bundle member hash, recomputes timing quantiles and checks the self-contained landscape on desktop/mobile and without JavaScript. Feature IDs/statuses and stock competitor cells remain unchanged.
