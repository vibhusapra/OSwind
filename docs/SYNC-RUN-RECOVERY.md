# Routine import recovery and authored scale

Component qualification on `codex/sync-routine-recovery`, extending the [incoming recipe/run adapter](SYNC-INCOMING-ROUTINES.md). Production sources remain identical to `f0aac3606b856f1c4977fd6ff4ded8078f7b4968`; this work adds tests, independent readers and measurement evidence. F059 remains TODO.

## Process recovery

Four parent tests create separate producer/receiver libraries, run an owned xctest worker, observe its explicit gate and kill only that worker with SIGKILL. They cover first import and a later run-status update, each immediately before and after journal commit. A precommit kill must preserve the prior state or leave no partial original; a postcommit kill must preserve the native run, exact original recipe/status, cache versions and causal head together.

Recovery inspection does not drain outgoing work. Retry then applies an uncommitted operation once, while a committed duplicate executes no adapter callback. The update fixture edits the current recipe before finishing the earlier run, so recovery must retain the earlier prompt and running wire version. Paused recipes never execute. The exact producer packets, native frames, original payloads, global/local bindings, durable recipe metadata, journal heads/clocks/cursors/receipt digests and accounting are independently checked after closing both libraries.

The independent reader covers eight recovered/retried states and sixteen unchanged SQLite files. Ten deliberate corruptions are refused, including a retargeted durable recipe with a recomputed checksum, a forged causal clock with its exact head intact, and a native message correction with recomputed local frame hashes. This establishes process-death behavior for these authored cases; it does not establish physical power-loss behavior.

## Warm metadata measurements

One warm sample per size on Apple M5 Max/128 GiB, macOS 26.6.2, Swift 6.3.3. Power and thermal state during measurement were not captured:

| Phase | 1,000 runs | 10,000 runs |
| --- | ---: | ---: |
| Receive exact originals, native runs and wire/cache metadata | 18.71 s | 187.32 s |
| Ten later run updates, retaining old wire versions | 0.268 s | 0.215 s |
| Native history read, 100 results, median of seven warm samples | 20.36 ms | 19.14 ms |

The receive timer includes actual producer packet reads and 128-record SQLite transactions, plus one current recipe update. Each original recipe has a 1 KiB-padded prompt; the current editor has a different prompt. Producer population uses explicitly authored raw SQL and is setup, not an API-ingestion measurement. Outgoing preparation is measured separately. Models, media, policy inference, network/transport, cold cache, physical power and product ranking are excluded. History timing includes database decoding/provenance reads, not UI rendering.

The independent scale reader checks all 11,000 actual producer packets, native frames, exact old definitions, current projections, durable recipe bindings, receipts and accounting, plus twenty retained pre-update versions. Twelve admission/corruption controls refuse incomplete or zero-test runs, changed compiled inputs, invalid timings, missing guards, retargeted originals, forged native bindings and receipt digests. All four SQLite files remain unchanged.

## Frozen qualification and remaining delivery

The [public receipt](../benchmarks/sync-run-recovery-v1.json) and [693-file manifest](../benchmarks/sync-run-recovery-inputs-v1.json) retain thirteen passing qualification stages. Full/default passes 1,565 cases with 79 explicit skips. Selected TSan passes 42 with four skips; optimized passes 43 with three skips, including the source-scale entry. No race warnings appear in the parent or ten retained child logs. All three builds' recovered/retried states receive independent review: 48 unchanged SQLite files in total.

The final scale oracle binds captured prior versions to the producer's actual journal content references. The preceding oracle admitted a forged prior body when its trace was changed to match; that counterexample and both oracle versions are retained. The strengthened review and twelve controls pass on unchanged data. No Swift, runtime or benchmark code changed for this repair. All 441 source/test inputs match across measurement and build gates; 330 product inputs are identical to `f0aac360`. The existing 34-file signed app/ZIP and installed 15-file app are unchanged; the staged signature is reverified and no new app build is claimed.

Schema-29 source receive takes 9.56/93.29 seconds at 1k/10k versus the prior schema-28 sample's 8.93/90.66 seconds; ten cited updates take 1.70/1.75 seconds. The scale-test source is identical, but these are separate single warm samples with uncontrolled cache/system/thermal state. Their observed +7.1%/+2.9% receive deltas are not a controlled attribution or statistical regression estimate. All 11,000 sources and 60 original projections pass the independent source reader and eight corruption controls.

- [x] Owned-worker create/update pre/postcommit SIGKILL, exact recovery and idempotent retry in debug, sanitizer and optimized builds.
- [x] Independent recovery/scale review and ten/twelve corruption controls.
- [x] Frozen full/default and selected sanitizer/optimized regression; parent/child race-log review.
- [x] Authored schema-29 source-scale regression and explicit comparison with the earlier sample.
- [x] Final checked inputs/receipts and unchanged-production-package verification.
- [ ] Complete entity/alias/mention/correction/deletion adapters and privacy/epoch/media/service integration.
- [ ] Enrollment/recovery/conflict UI, encrypted providers, actual two-Mac and physical/distribution acceptance.

These checks qualify an internal adapter. They enable no synchronization service and do not change any of the 78 feature statuses.
