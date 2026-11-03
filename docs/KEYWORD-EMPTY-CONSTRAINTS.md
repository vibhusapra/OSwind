# Empty required constraints stop before ranking

Runtime `5a3f888b540560d15c85754553c6f460e0830fe4` checks whether a required content expression can match anywhere in the current SQLite snapshot before ranking candidates. A missing required phrase previously made broad soft matches pass through an unsuccessful exact predicate one by one. The new check uses both content and speaker FTS, deduplicates atoms within one search, and retains no cross-search cache.

These are necessary conditions. `AND` needs both operands to remain possible; `OR` needs either. Negation remains possible without a global absence inference. Atoms found on different sources or separate speaker labels do not establish a complete matching source. The existing row predicate still applies before `LIMIT`; ranking, ties, source fields, schema, embeddings and generation requests stay the same. Literal and unconstrained queries add no probes. Cancellation uses the existing snapshot/progress/error cleanup.

## New native component diagnosis

Before the change, a new **48,000-record**, 34,652,160-byte minimal authored fixture ran through macOS `/usr/lib/libsqlite3.dylib` **3.51.0**. Six cases × five query shapes × nine measured rounds produce **270 observations plus 30 excluded warmups**. This reconstructs relevant current FTS/canonical-ID/stable-key/speaker tables; it is not the complete product database, Swift hydration or command startup.

Broad ranked-ID medians were about 53 ms; ranked full-payload medians about 52–55 ms. The absent-phrase full query was about 287 ms. Boolean and restrictive-metadata predicates also showed substantial candidate rejection costs. The query shapes perform different work and their differences are not additive overhead estimates or causal performance proof. Unranked controls change ranking semantics and are diagnostic only.

All source/payload memberships and recorded timings are checked independently from the generator. Seven metadata-eligible sources lie outside the initial unconstrained top 100, so moving eligibility after `LIMIT` fails. Separate native controls retain speaker-only phrases and terms split across body/speaker or separate labels. Eight altered-record checks reject. The successful profile, review, source pins and results are frozen; earlier successful comparisons are not repeated.

## Separate paired actual CLI workload

The opt-in seed uses actual `MemoryStore.insert` with no embedder/model to create a new 48k native archive using the same declared text/title/app families. This is a separately declared workload, not a reuse of the earlier 100k competitor corpus. The previously qualified `9245805` package and this candidate each open their own copy. Seven new cases run seven rounds in alternating product order with seeded case shuffling. One complete warmup per case/profile is excluded.

All **98 measured processes plus 14 warmups** have matching ordered complete result signatures within each case across the two binaries, excluding only reported duration. Physical source rows/payloads and settings remain identical in both copies. Every returned ID, authored body/title/app, score, expected count and constraint is checked. Missing phrases return zero; a rare exact phrase returns one; the metadata case returns all seven eligible sources. A possible Boolean OR branch remains eligible.

Median milliseconds, seven observations per cell:

| New authored case | Baseline CLI ms | Candidate CLI ms | Baseline search ms | Candidate search ms |
| --- | ---: | ---: | ---: | ---: |
| soft-broad | 86.75 | 89.22 | 55.07 | 57.03 |
| required-broad | 91.03 | 91.20 | 57.87 | 58.55 |
| required-rare | 32.20 | 32.42 | 2.01 | 2.25 |
| boolean-exclusion | 190.53 | 188.21 | 158.05 | 155.55 |
| metadata-after-ranked-decoys | 224.07 | 206.26 | 193.54 | 173.96 |
| absent-phrase | 479.32 | 32.02 | 446.50 | 1.87 |
| nested-or | 66.74 | 66.77 | 34.16 | 32.65 |

The soft broad CLI median increases from 86.75 to 89.22 ms; the full table retains these mixed observations. The samples do not establish whether small differences are caused by this implementation.

Raw process wall time includes startup/opening/output/shutdown; reported search duration is measured by the product. Same-device caches and background activity, including the separate owned capture soak, remain uncontrolled. Small descriptive observations do not establish controlled cold-start, general latency, energy, competitor speed or ranking. The retained [stock CLI comparison](OFFLINE-KEYWORD-COMPARISON.md) still records Screenpipe's advantage on its older broad case. This change targets globally impossible required operands; it does not resolve broad relevance ranking cost.

## Software qualification and retained limits

**712 committed inputs**, 709 prior inputs unchanged; three source/test files. Eight new ordinary behavior/cancellation methods plus one gated owned seed. Full Debug **2,619 passed / 164 conditional skips**; affected sanitizer and optimized **347 passed / eight skips each**; explicitly gated optimized seed **one passed**. Zero failures and no race diagnostic. Existing test identities/states, exact new method selection, raw log hashes and five altered-log controls are checked. Normal release build/fresh strict ad-hoc package pass; previous resources/bundle information remain unchanged. The first normal release build failed with ENOSPC. After reclaiming only inactive generated compiler caches, a separate continuation resumes that failed build and the previously unstarted package at unchanged inputs. All five earlier successful stages remain adopted without repetition; the failure, continuation and cleanup scopes are retained. The initial eight-method development run also passes.

The paired review checks all 112 raw results, timing summaries, binary pins, physical source/settings identities and seven altered-answer refusals. Component, product timing and software qualification remain distinct evidence. There is no GUI/input, physical two-Mac sync, sustained capture/power, production DP-Keychain, Developer ID/notary, full-v0 or top-three acceptance. All 83 feature statuses remain unchanged.

[Runtime receipt](../benchmarks/keyword-empty-constraints-v1.json) · [Inputs](../benchmarks/keyword-empty-constraints-inputs-v1.json) · [Raw evidence](../benchmarks/keyword-empty-constraints-raw-v1.zip). The archive retains scripts, plans, SQL/results, development/full/sanitizer/optimized/build logs, current/preceding component source and paired stdout/stderr. It contains no databases, binaries, model weights, user history or keys. All 496 preceding benchmark files remain byte-identical.

Primary references: SQLite [FTS ranking](https://www.sqlite.org/fts5.html#the_rank_configuration_option) and [statement counters](https://www.sqlite.org/c3ref/c_stmtstatus_counter.html). Outer VM counters do not account for all virtual-table work; zero SQL sort/fullscan counters do not mean ranking is free.
