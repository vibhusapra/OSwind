# Optional conversation references in completed runs

Deleting a conversation preserves independent run history. A completed run that arrives after its optional conversation was erased now imports with no native conversation link while retaining its exact original packet, recipe attribution and recorded status. Deleting a conversation already linked to an imported run preserves the same original instead of letting the native foreign-key update invalidate it.

This is an internal sync component on schema 31. F059 remains TODO. No public sync service, enrollment or provider control is enabled, and no wire or database schema changes are introduced.

## Behavior

| Situation | Result |
| --- | --- |
| Optional conversation has a genuine durable deletion barrier | Preserve the independent run and exact original; native `chat_id` is null |
| Conversation is missing but has no deletion barrier | Retry; no acknowledged run or invented deletion |
| Owning recipe or evidence is erased | Existing owning/evidence retirement rules remain required |
| Entity scope is erased | Still required and unfinished; never replace it with an unscoped query |
| Native or peer deletion after an imported run exists | Atomically detach the nullable link and update its exact native fingerprint |
| Optional conversation restored under a new lifetime | Old run stays detached; a reused native primary key cannot satisfy the old reference |
| Quiet backup restored and reenrolled | Preserve original recipe/status; use fresh catalog identities without reviving the old conversation lifetime |
| Required cached original packet is missing during peer projection or wire reconstruction | Refuse that projection; do not rewrite the packet to hide the missing reference |

The peer deletion prepares linked originals before catalog echo suppression. Each detachment requires the owning connection and transaction, the exact old eleven-cell native frame and original bytes, and a permit for the new frame differing only in the nullable conversation cell. It rebinds the exact cached run packet before the conversation foreign key fires. Erasure does not invoke recipe body-policy, dependency-fetch or media callbacks through this preparation.

Enumeration follows the existing partial conversation index and SQLite rowid in batches of 128; it does not collect all affected originals. Cancellation, a failed delete, and the incoming receipt share the transaction. Public native conversation deletion uses the same original-preserving detachment helper.

## Evidence and limits

Thirteen mandatory software controls cover unseen/known runs, local deletion and outgoing progress, exact Unicode prompts, missing-live refusal, quiet restoration, duplicate deletion and native-key reuse, 130 linked runs including the minimum negative rowid, foreign connections/changed frames/absent transactions, cancellation after detachment, delete-trigger rollback, missing-cache refusal, and actual pre/postcommit SIGKILL recovery. The guarded worker entry point is skipped in ordinary discovery and invoked by its two parent tests.

Retained failures include the unseen run blocking its sender, the native foreign key discarding provenance, preparation inside suppressed catalog mutation, missing-cache fallback, unnecessary recipe policy callback, and test/harness mistakes. A passing control subset is not a whole-product claim. The final receipts below preserve the completed qualification and its limits.

The libraries, journal trust membership and raw scale population are owned fixtures. These checks do not establish network authentication, transport, production media/policy/epoch handling, public enrollment/recovery/conflict UI, actual providers or two physical Macs. Physical capture, sustained energy, notarized distribution and competitor ranking remain separate delivery gates.

## Frozen qualification — November 1, 2026

The [804-input receipt](../benchmarks/sync-optional-references-v1.json) qualifies source `5aa0c10d311b39b0189d6f797e36a73b1d9f7afe`. All 18 stages pass: full debug **1,896 passes / 94 explicit skips**, broad Thread Sanitizer and optimized **433 passes / 32 explicit skips each**, and **39 owned native vault passes / no skips**. Every one of the 13 new mandatory methods executes in all three builds. Six separately retained pre/postcommit worker fixtures pass independent closed-database review of original bytes, every native frame cell, current cached packets/fingerprints, barriers, receipt hashes and sequence cursors. The full/native selections cover 1,933 distinct passed methods; other opt-ins remain unqualified here.

A newly staged ad-hoc-signed app passes API/MCP/SDK, native chat deletion, recap/routine, interrupted backup, vault, controlling-PTY reader and query-child interruption processes. Strict staged/extracted signatures and all 34 file hashes agree. All 30 earlier app trees remain unchanged. This is ad-hoc signing, with no notarization claim. The [repository input manifest](../benchmarks/sync-optional-references-inputs-v1.json) records exact Git-matched source/test/script/resource inputs.

## Current warm metadata observation

The [single optimized observation](../benchmarks/sync-optional-references-performance-v1.json) uses a separately pinned test bundle. Independent review verifies all 11,000 actual producer/current/native/original/recipe bindings, twenty retained pre-update packets, journal receipts and accounting. Raw population is authored fixture setup, not public API ingress. These positive-path records have no optional conversation; this does **not** measure the new detachment path's latency.

| Runs | Incoming projection | Outgoing preparation | Native history, 100 rows, warm median |
| --- | --- | --- | --- |
| 1,000 | 17.909 s | 14.540 s | 16.496 ms |
| 10,000 | 177.755 s | 143.985 s | 16.481 ms |

Host: Apple M5 Max, 128 GiB memory, arm64; OS/compiler versions are recorded in the receipt. There is one observation per size and seven warm history reads. Caches, background work and thermal state are uncontrolled. No paired baseline, causal speedup, model/media/transport, cold-cache, physical-power or whole-product ranking result follows. The 130-linked-run test is a bounded correctness control, not a deletion-throughput benchmark.

## Reproduce the software controls

The committed `Tests/OSwindCoreTests/SyncOptionalReferenceTests.swift` extends `SyncIncomingSourceTests`. Run the complete class with `swift test --filter SyncIncomingSourceTests`. For retained before/after-commit fixtures, set `OSWIND_TEST_INCOMING_SOURCE_ROOT` to a fresh absolute nonsymlink owned output path and select `SyncIncomingSourceTests.testOptionalConversationDeath`. The two parents launch their guarded worker and SIGKILL only that owned process. Do not invoke the worker directly against arbitrary libraries.

Sanitizer selection: `swift test --scratch-path /absolute/fresh-tsan --sanitize=thread --filter 'Sync|Routine|Conversation|Historical|LibraryWipeModel|VaultSession'`. Optimized selection uses `swift test -c release` with the same filter. Native vault tests require explicit `OSWIND_TEST_NATIVE_VAULT=1` and create their own encrypted fixtures; they do not use personal libraries. The positive-path metadata fixture is `testOwnedIncomingRunProjectionAtBoundedScale` with a fresh explicit `OSWIND_TEST_SYNC_RUN_SCALE_OUTPUT`.
