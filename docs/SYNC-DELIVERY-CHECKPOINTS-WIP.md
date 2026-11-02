# Checkpointed signed delivery — internal WIP

The pairing owner now has an internal preparation path into the real signed sync service. It durably reserves the delivery credential account in its existing Keychain envelope before installing the native checkpoint. A restored pre-install database therefore cannot allocate a replacement account with a zero floor. Missing credentials and existing assigned histories are recovery conditions. The public pairing preview still does not activate delivery; F059 remains TODO.

A separate bounded Keychain envelope holds the original device/group/owner material, native/Mac/installation/physical binding and an externally saved checkpoint. A held per-account process lease owns it. The native database stores only an account/protection identifier and a serial/nonce checkpoint. Key material is never added to SQLite or provider objects.

## Native commit boundary

Native triggers advance the checkpoint on changes to assigned local operations, peer cursors, registers, receipts, pending and expected operations, observation clocks, approved/received collection controls, observed peer heads and sent progress. Ordinary capture remains unassigned local intent. The service also stamps changed native preparation/projection transactions, including projections retried without a new receipt.

The service validates its current external checkpoint before work and inside publication fences. Mutating service phases run in an owned outer SQLite transaction. After their work, the external checkpoint is saved before SQLite COMMIT; incoming native effects therefore cannot become visible before their checkpoint exists. Native history publication writes are kept outside those mutating phases and behind read fences. Setup may create an encrypted space marker before history is assigned; it does not publish native payloads. Recursive supersession is covered by the complete durable assigned history, rather than only the requested outgoing batch.

This is not an atomic Keychain/SQLite transaction. A failure before external advancement rolls native work back. An attempted or ambiguous external save stops the current owner and requires reopening. If Keychain advances and SQLite commit fails or the process dies in the gap, the external floor remains ahead: recovery is required, and neither the account nor checkpoint is silently reset. Cancellation after successful external advancement finishes the critical native commit. A normal advertised peer head ahead of its applied cursor remains valid partial delivery.

Schema checks use SQLite's schema cookie to revalidate changed protection. Private material stays cached for the owner; idle ticks do not re-decode it. Idle queue/requeue validation avoids toggling processing flags, unchanged peer hints avoid native UPDATEs, and unchanged sent progress is not rewritten. Quiet ticks are checked for zero credential replacements and unchanged encrypted provider bytes. This is an idle-work invariant, not a sustained power measurement.

## Development evidence and boundaries

New cases cover actual internal pairing-to-service setup/reopen, partial transfer, database rollback before and after delivery installation, lost credentials, changed checkpoint hooks, unowned wire mutations and same-sequence body substitution, save/commit failure, idle work and public-preview nonactivation. A separate WAL reader proves an early out-of-order deletion is still uncommitted when its external checkpoint advances; restoring its earlier native database is refused even though the contiguous peer cursor remains zero. The all-13-kind case reopens at cursor one and completes cursor 21 with exact immutable wire bodies, original evidence bytes and no echo. An explicit disposable login-Keychain case exercises actual credential persistence and confirms account removal.

Earlier development failures remain retained, including the real idle Keychain-write regression and its correction. A deletion fixture initially called a high-level standalone transaction from inside a journal transaction; it now uses the same native SQL transaction for its owned effect. Another fixture incorrectly expected producer and receiver historical-original table counts to match; imported immutable originals are separate from live native sources. The corrected case checks exact original wire bytes and all 21 source/receiver wire bodies instead of that invalid count equality.

Source `5102714` now has its own [1,485-input manifest](../benchmarks/sync-delivery-checkpoints-inputs-v1.json) and [independently reviewed qualification](../benchmarks/sync-delivery-checkpoints-v1.json): full Debug **2,410 passed / 135 skipped**, sync Thread Sanitizer **591 passed / 34 skipped**, optimized **591 passed / 34 skipped**, and explicit owned Keychain **17 passed without skips**. All four retained all-kind fixtures independently match 13 native counts, 21 exact wire bodies, two original evidence bodies, both public external checkpoint tokens, receiver cursor 21 and zero outbox echoes. This is local internal-service qualification; later runtime changes need their own receipt.

## Required before public activation

- [Native writer admission and recovery](SYNC-NATIVE-ADMISSION-WIP.md) now have an explicit internal vertical slice. Its separate native34 qualification is now recorded at source `ff23280`; later lifetime retirement and public activation remain required.
- Recovery/quarantine and credential phase/lease handoff; a failed external/native boundary must not make local data irrecoverable.
- Actual local and received whole-erase producer drain, physical cleanup and exact completion-based binding/checkpoint renewal. Current retired lifetimes refuse delivery; this is not a completed erase/reconnect flow.
- Public folder/session setup through the app's owned preparation lifetime, membership refresh, revocation and rotation. The reserved credential deliberately refuses membership edits/local pairing-key retirement behind the delivery owner.
- Offline raw-queue backpressure, cold-provider behavior, large resumable graphs, selective spool/backup behavior and actual signed-app/two-Mac/provider/power/distribution acceptance.

The checkpoint covers consistent native SQLite snapshots through the implemented mutation boundary. It is not a global freshness oracle against provider withholding, a defense against malicious selective SQL edits or whole-OS/Keychain rollback, hardware device-only storage, or evidence of whole-product parity/ranking.
