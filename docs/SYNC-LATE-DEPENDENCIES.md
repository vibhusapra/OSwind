# Late dependent sync records

An offline device can create an answer, recap, run or entity link before learning that another device erased its parent. Previously, receiving that unseen child tried to prepare an erased dependency, rolled back and blocked later records from the same sender. The internal common writer now retires that admitted lifetime in the receipt transaction and can continue to an independent later record.

This is a functionally qualified internal component on schema 31. [All 22 local stages pass](../benchmarks/sync-late-dependencies-v1.json), with [725 repository input hashes](../benchmarks/sync-late-dependencies-inputs-v1.json). Complete synchronization and F059 remain unfinished. The new writer now has a complete warm positive-path paired receipt below; late-only scale and broad performance acceptance remain open.

## Behavior and ownership

Canonical packet bytes must match an actual admitted head. The writer reads durable parent states before body-policy, dependency-fetch or media callbacks. If an owning/evidence parent is already deleted, it publishes a genuine local deletion and uses the existing native/catalog/cache retirement transaction. The deletion context must dominate the parent barriers and every admitted child head. A failed announcement rolls back the incoming receipt, cursor, local sequence, observed clock and barriers together.

| Incoming kind | Owning/evidence dependency |
| --- | --- |
| Recap source | Sources embedded in its authoritative recap packet |
| Turn | Conversation |
| Answer/recap citation | Owner and exact source lifetime |
| Routine run | Recipe lifetime |
| Alias | Entity definition |
| Mention | Source and entity definition |
| Name correction | Source |
| Project correction | Source and project definition |
| Evidence pin | Source |

Independent conversation, recipe and entity definitions acquire no dependency retirement solely to make projection easier. Missing live owners remain retryable, with no false barrier or acknowledged child. Ordinary positive conflicts still require review. Privacy retirement may retire a conflicted lifetime only when its supplied packet matches an admitted head; its barrier observes all concurrent heads.

An erased answer citation also retires its answer lifetime conservatively. A derived recap row cannot erase an independent named source merely by claiming it as owner; the recap source's own packet carries its authoritative source list. A canonically valid stale row referencing erased evidence can be retired without projecting its body or inventing a dependency fetch.

`applyOutcome` returns either a projected local identifier or an explicit retired lifetime/parent list. The internal compatibility `apply` returns an empty string for retirement. Future service code must distinguish outcomes explicitly and route already-deleted journal changes through deletion handling.

## Verified evidence

Seventeen new methods cover turns, runs, aliases, mentions, name/project corrections, recaps, pins, answer-citation owner retirement, stale recap ownership, missing-live preparation, concurrent heads, reservations/connections, cancellation and actual pre/postcommit process death. Sixteen are mandatory parent cases; the guarded crash worker runs only in its owned subprocess.

The finalized 23-case selection passes 22 / one worker skip. The same exact fixtures fail against the old writer with 45 assertions / 14 unexpected errors; compilation and fixture mistakes are retained separately. The final frozen qualification reports:

- Full debug: 1,635 passes / 82 explicit skips/zero failures.
- Broad Thread Sanitizer and release: 635 passes / 22 explicit skips each; all 16 new mandatory cases execute in every build.
- Seventeen retained parent/worker sanitizer logs contain no race warnings. Both new crash-worker logs are retained. Parents SIGKILL only their own worker before/after receipt commit, inspect the actual database before opening, then verify retry, causal barriers and later sender progress.
- Eleven corrupt copies of actual indexed benchmark output refuse; restored positive review passes and original databases remain unchanged. Prior actual projection/original evidence also passes independent review.
- A new ad-hoc-signed app passes SDK/API/MCP, actual old30 refusal, entity/correction/metadata, capture, original erasure, deletion/wipe, recap/routine and interrupted-backup processes. Strict staged/extracted signatures and all 34 file hashes agree. Installed 15 files and four prior staged trees remain unchanged.

## Remaining delivery gates

- Verify early out-of-order parent tombstones followed by unseen children while predecessor gaps remain.
- Preserve optional deleted references separately: an erased entity filter must not become an unscoped query; deleting an independent optional conversation must not delete an unrelated run or discard exact original provenance. These paths are unimplemented.
- Add publication-group/epoch visibility before exposing an answer whose citation edges have not arrived. Per-record retirement cannot infer unseen edges.
- Finish scoped/wipe collection barriers, compaction, production policy/media/transport admission, service/enrollment/recovery/conflict UI and actual providers/two-Mac acceptance.
- Measure candidate-only late-record scale; positive-path pairs below are complete. Warm component results do not establish physical power, native sustained capture, distribution or competitor rank.

Parent PR #113's first hosted native job failed in `testNativeChangedSourceSnapshotDoesNotSwitchOrLockTheOriginal`: detach exits 16, its destination remains closing and its owned image is preserved. The build/test step and benchmark job pass. Artifact 13061034823 and all five assertions are retained; those uploaded traces do not cover this exact migration, so its cause remains unproven. A pinned local release single-case reproduction passes without reader samples; the unmodified local debug group passes all 37 cases, with 23 limited reader samples across nine owned roots. This does not identify the CI cause. One unchanged-head comparison now passes both hosted jobs in run41250799261; PR114 also passes both jobs in run41253317555. These successes do not resolve the original cause or replace its retained failed attempt.


## Positive-path paired observations — October 31, 2026

The complete [performance receipt](../benchmarks/sync-late-dependency-performance-v1.json) retains all twelve original slots in AB/BA/AB order, all 24 size/workload observations, setup/load costs, whole-process wall times and 60 read-only storage inspections. Independent content checks verify 66,000 exact originals, 120 retained prior versions and 66,000 causal child barriers. Eleven real copied-data corruption controls refuse; the restored positive passes and original files remain unchanged.

Both freshly staged optimized bundles compile the same 725 inputs except `SyncIncomingConversationWriter.swift`. Baseline is the published `b38a9de` writer **plus** the same unused helper and five late-dependency test files compiled into the `e453bf6` candidate. Dependencies/toolchain match. All 1,450 live input hashes, copied payloads, private controls, reports and logs match at final review. Source-only calendar editing ran in a separate checkout; no local compilers or tests ran during the experiment. Caches and unrelated background activity remain uncontrolled.

| Metric | Baseline median | Candidate median | Change |
|---|---:|---:|---:|
| 10k incoming projection | 183.884 s | 182.226 s | -0.9% |
| Whole projection workload, both sizes | 365.624 s | 364.284 s | -0.4% |
| 10k child deletion | 21.433 s | 20.240 s | -5.6% |
| Whole deletion workload, both sizes | 184.897 s | 183.244 s | -0.9% |
| 10k projection outgoing preparation | 144.789 s | 145.643 s | +0.6% |
| 10k native history, 100 rows | 16.918 ms | 16.965 ms | +0.3% |

Three pairs do not establish statistical significance or a causal speedup. The first 10k deletion pair is slower in the candidate; retain every raw pair rather than quoting only its lower median. Random fixture identities and ordinary SQLite page variation are visible in per-file sizes. Both profiles retain the existing covering index; no new index/schema is introduced by this writer. Median 10k receiver index sizes in projection are about 1.38 MB baseline / 1.35 MB candidate; fanout receiver indexes are 1,355,776 bytes in all six samples. These are observations, not a new storage optimization claim.

This qualifies the completed measurement and its content/admission checks. It excludes late-dependent-only scale, model/media/transport, cold caches, sustained capture, physical energy, full sync service and competitor ranking. F059 and all 83 feature statuses stay unchanged.
