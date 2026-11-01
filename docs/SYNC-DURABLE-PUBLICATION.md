# Durable answer admission

**Internal component; F059 remains TODO.** This adds no public enrollment, background watcher, provider connection or automatic capture. It is stacked on [complete answer declarations](SYNC-ANSWER-PUBLICATION.md). Native schema remains 32.

A received operation and a readable native answer have different completion conditions. The receiver can durably acknowledge an authenticated operation while withholding its answer until its exact declaration, ordered citations, originals and current local policy are ready. The admission queue preserves that pending work across restart without storing raw questions, answers, source excerpts, paths or credentials in its work metadata.

## Behavior

| Event | Result |
| --- | --- |
| Owner/declaration/citation missing | Persist one coalesced owner job and indexed dependency/declaration keys; publish no partial native answer. |
| Explicit policy denial | Roll back the attempted native group, preserve an explicit policy-blocked job and receipt, and require a later review/wakeup. Other errors and cancellation remain failures. |
| Pending/binding quota exhausted | Refuse or withhold explicitly; preserve existing work and accounting. Never silently evict an earlier job. |
| Declaration/content arrives | Wake only matching indexed work; retry a bounded current-head batch. A receipt alone never proves native completion. |
| Newer owner head is withheld | Physically remove the stale native answer/citation graph and cached bodies while preserving exact live global identities and local IDs. No visibility-only UI filter or placeholder payload is used. |
| Actually declared citation changes | Recheck its previous native owner and current declaration. Withdraw stale publication when necessary. Unrelated unlisted IDs and old catalogue mappings without a live native citation cannot withdraw an independent completed answer. |
| Required evidence is erased | Withdraw the affected answer version, preserve authentic source/pin/citation barriers, and keep independently valid future/concurrent answer heads possible. Direct answer/conversation deletion remains permanent. |
| Source erasure scrubs a conversation title | Publish a genuine fixed-title canonical metadata revision that observes the authentic source barrier. Preserve valid native/canonical dependencies for later independent answers. |
| Early deletion crosses missing causal context | Withdraw old readable evidence immediately and preserve bounded durable work until contiguous applied cursors close the gap. An observation clock is not proof that predecessors applied. |
| Wrong inbox group/epoch, stale/wiped lifetime, closed library | Refuse before retaining private encrypted content. Retry also refuses a foreign namespace without rewriting its durable work reason. |
| Declaration arrival inside an SQL transaction | Refuse before retaining bytes or taking a media lock. Normal declaration retention reserves a shared library lease before its SQL/retention work, coordinating with wipe/close. |

The dispatcher selects current-version evidence invalidation. The older lower-level publication coordinator retains its legacy lifetime-retirement default for existing internal callers. Neither path is a public sync service; future service entry points must use the owning dispatcher and current policy/media adapters.

## Storage and transaction boundaries

- Optional internal metadata shares the library's own SQLite connection. Exact DDL, durable capture mode, namespace, generation and a dedicated queue-library lifetime UUID are checked. Ordinary search-cache identity rotation does not revoke queue authority; native wipe does.
- Work is capped at 4,096 jobs and 121 dependency keys per owner. Retry/wakeup batches are bounded to 256. Logical charges are 512 bytes/job, 128 bytes/dependency and 256 bytes/completion binding. Defaults are 64 MiB per budget, maximum 8 GiB. These are logical metadata limits, not whole-library or encrypted-folder disk quotas.
- Owner/native citation changes invalidate completion bindings using existing schema-32 functions. Completion requires the exact current owner head/declaration and every declared native citation, with no undeclared extra rows.
- Retraction temporarily relocates only live non-revoked catalogue bindings inside the owning transaction, deletes the native graph under echo suppression, then restores the original key frames. No deletion flag, global tombstone or permanent revocation is cleared. Readers see the prior committed graph or its committed absence.
- Encrypted canonical content is durable before its receipt. Scope checks run before that retention. A later policy/quota/cancellation/SQL failure can still leave an unreferenced encrypted object; production quarantine and garbage collection remain open.
- Source erasure commits native/original/cache deletion, genuine derived pin barriers, canonical redaction and durable media cleanup entries together. Actual file unlinking is deferred cleanup, after media reservations permit it. SQL acknowledgment is not proof that every file has already been unlinked.

At source pressure, the tested contract is an explicit refused root receipt with complete rollback of redaction, graph, clocks and work. Restoring capacity permits the same operation to retry without eviction. A production service still needs an erasure-priority strategy so a permanently full work queue cannot indefinitely delay erasure.

## Verification

[Software evidence](../benchmarks/sync-durable-publication-v1.json) at `4cbe898` records 2,005 full passes / 97 explicit skips, 594 sanitizer and optimized passes / 38 skips each, all 51 mandatory controls in all three builds and eight independently reviewed closed debug crash snapshots. The [input manifest](../benchmarks/sync-durable-publication-inputs-v1.json) binds 1,324 tracked repository files to Git source; it is not dependency/toolchain attestation. Current-source package/native/hosted acceptance remains separate. The [delivery ledger](PROGRESS.md) preserves earlier checkpoints under their actual source hashes.

The mandatory admission controls include real outgoing canonical records, actual incoming journals, separate owned libraries, authenticated encrypted object folders, restart/retry, policy denial, quota rollback/recovery, native wipe, original promotion, old/reused/unlisted citation behavior, future/concurrent versions, namespace refusal and no-write stale/closed-library retention.

Process-death controls use actual SIGKILL with an independent SQLite reader. Three phases cover projection retraction; five further phases cover canonical source redaction, answer withdrawal, native source deletion, precommit and postcommit. An owned PNG proves durable asset queueing and explicit cleanup. Independent read-only Python/SQLite review checks native frames, key frames, cache/work accounting, authentic barriers, canonical metadata, receipts, database/WAL bytes and media state.

The actual frozen prior schema-32 CLI is SHA-256 checked before/after. Its initialized writer is observed before queue installation using its exact file descriptor and a direct shared/exclusive flock probe. It then writes after retraction/source erasure. Fresh old processes read/export/delete the graph and invalidate completion accounting. This proves that tested executable's native writer/fresh-reader behavior; it does not prove an already-rendered GUI refresh, every older app, every media concurrency path, or provider/two-Mac acceptance.

Typical software invocation:

```sh
swift test --filter SyncIncomingSourceTests.testPublicationQueue
```

The two actual older-client methods opt in with `OSWIND_TEST_PUBLICATION_OLD32_CLI` pointing at the exact qualified executable with SHA-256 `ce600b7d4c74eaaba65db61050b9b369a05352a9fe80c145e7a438448e01e6e2`. They skip without that artifact; the local qualification must execute them explicitly. Rebuilds of old source are not silently treated as that same executable.

## Required before public sync

Current-source package/signing/native/hosted checks remain separate from software tests. Complete service lifecycle/actor ownership, enrollment and key recovery, policy/media transport, encrypted orphan cleanup, collection epochs and unknown offline-object erasure, backup rollback/recovery, revocation, acknowledged compaction, transitive recap/version retirement, conflict/status UI, actual providers/two Macs and sustained power remain open. Held-reader media cleanup, already-rendered GUI behavior and fresh-machine setup require their own acceptance. No competitive throughput, energy or top-three rank is established here. All 83 feature statuses remain unchanged.
