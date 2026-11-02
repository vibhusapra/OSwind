# Collection erasure and owning sync transport — internal WIP

OSwind now has an internal sender over the actual native journal, typed version cache and encrypted object folder. A local whole-library wipe pauses export until an explicit group-erasure review is durably bound to the captured cutoff, group and epoch. The native local wipe action does not grant permission to erase other devices.

## Implemented boundaries

- Native creation eras survive delayed processing and restart. An edit cannot renew an old lifetime. Unseen old lifetimes are rejected before their bodies are fetched or native rows are projected; genuinely later creations survive.
- Canonical body-free group controls use a separate authenticated cipher purpose. The receiver checks group, epoch, enrolled claimed creator, exact replay and forks. Only the creator axis advances: a frame's claimed foreign context is not evidence that foreign erasures were observed.
- Control delivery bypasses a full ordinary pending queue. Control receipt, frontier and required retirement callback share a transaction. Callback failure rolls back the receipt and native changes.
- The sender refuses every packet after an unreviewed local wipe, including canonical deletion headers. Reviewed controls precede ordinary records. Previously erased or deleted puts can retain their original immutable operation header without exporting their missing private bodies.
- Authenticated causal supersession proofs let a lagging peer advance an obsolete header whose body was pruned. The proof retains the exact opaque successor header across restart/provider withholding; its eventual operation must match. It does not invent a cursor or native source body. Proof identities remain immutable as later edits form a chain.
- The encrypted folder now requires an authenticated v2 marker declaring creation-era, collection-control and supersession support. It refuses an authenticated v1 space without mutation and never writes the v1 marker required by the old reader. There is no silent migration. This marker boundary is narrower than complete old-application wire acceptance.
- Transport ownership checks the current native capture generation and activation, including header-only paths. The receiver rechecks under its write transaction. A service controller must still cancel and join workers before acknowledging stop, library replacement or trust changes.

Group-secret AEAD authenticates the group and purpose. Enrollment checks the claimed creator; this is not a per-device signature or cryptographic proof of human review.

## Evidence and limits

The original unseen offline-source regression remains unchanged and passes the focused implementation checks. Tests use actual owned native libraries and encrypted folders, including local-clear export blocking, explicit reviewed controls, independent edits, out-of-order controls, forks, rollback, a full 4,096-operation pending queue, pruned bodies and restart. Original failing logs and source snapshots remain in the ignored `sync-library-barriers-v1` evidence directory. These are component preflights, not a complete source/package qualification or provider acceptance.

Two early scope tests were corrected to exercise the owning publication boundary: raw journal state is prepared local state, not publication. Their original logs and the actual native deletion caused by direct raw replay remain retained. Immutable receipts were not discarded to conceal those failures.

## Required before a public service

- Complete native group retirement: all 13 canonical kinds, unprepared native/raw work, cached originals/publications, media inventory and durable physical cleanup. Current required fixture callbacks retire actual known sources or verify an empty library; a no-op default is deliberately unavailable.
- Explicit old/new native and wire capability compatibility. Pure SQL wipe capture with a frozen older native writer is narrower than complete new-wire interoperability.
- Owning background controller, lifecycle registry/cancel/join, current-policy and media adapters, durable large-transfer cursors and bounded resumable graph work. Current budgets are finite refusal guards, not completed large-media transfer support.
- Pairing/trust, epoch rotation, revocation/recovery, backup rollback, metadata compaction, conflict/status and local-versus-group review UI.
- Real providers and two physical Macs; sustained power/CPU, native UI/input acceptance and signed/notarized distribution.

**F059 remains TODO. All 83 feature statuses stay unchanged. No feature-parity, energy, throughput or product-ranking claim follows from this work.**
