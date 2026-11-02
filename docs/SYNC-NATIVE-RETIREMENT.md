# Native group erasure — internal component

`SyncNativeCollectionReceiver` now supplies the required native adapter for a newly authenticated encrypted group-erasure control. It uses the receiver's existing exclusive media lease and SQLite transaction. This is internal infrastructure; no background sync service is enabled.

The adapter retires existing journal registers using their real heads and verified collection frontier, without inventing per-object deletion operations or advancing peer stream cursors. It clears raw capture and staged work through their accounting hooks, stages the actual native library wipe, purges typed/session/recipe/run caches and original projections, retires publication work and bindings, and clears reusable native key frames and bootstrap cursors. Immutable authored headers, receipts, expected successors and lifetime-era fences remain retained.

Received cleanup uses `library_group_wipe_dirty_v1`. It shares pending-cleanup, startup and retry behavior with local library wipes, while avoiding the local-intent SQL hooks. A received erase cannot approve a local wipe or author another local counter. Physical files stay present until the transaction commits; cleanup subsequently touches only sealed queued paths and preserves later media.

Retiring stale publication metadata requires the same group, epoch, capture generation, schema and accounting. A prior local wipe can leave its publishing authority invalid; authenticated erasure may clear that metadata without granting fresh publishing authority. Ordinary publication still refuses the invalidated queue.

## Qualified source and evidence

Source `2345a256525254a60ac52ec4077127ba330fb566` binds the [1,428-input receipt](../benchmarks/native-collection-retirement-v1.json): **2,286 full passes / 125 explicit skips**, **1,226 sanitizer and optimized passes / 71 skips each**, all **445 required controls** in every build, **62 native methods without skips**, and **9 additional native-collection fixture parents without skips**. Full plus native covers **2,346 distinct methods**; all nine collection parents are already in the full-suite count.

All **34 fresh package/process stages** pass. Independent review verifies every byte of the 34-file app/ZIP/extraction, strict ad hoc signatures, migration crash databases, current-source collection fixtures and 61 earlier app trees. The independent readers inspect seven SQLite/media snapshots, closed native-original and completed-binding fixtures, the local-clear regression, and actual database/WAL files retained after SIGKILL before and after commit. Integrity and foreign keys pass; headers and peer cursors remain unchanged, with no local erase echo.

The original candidate refused group erasure after a local wipe invalidated publication authority; its failure and fixed regression remain retained. Initial crash-parent failures came from strict inspection through macOS's `/var` alias; POSIX `realpath` corrects that fixture path while retaining read-only/no-follow flags. A failed reader attempt is retained separately from the fresh baseline that explicitly accounts for newly created empty coordination WAL files. Frozen successful readers are never rerun or relabeled as later source acceptance.

This qualifies the internal component locally. Public service/lifecycle, actual provider/device and whole-product acceptance remain separate requirements. Current-source hosted checks are a separate publication gate.

## Remaining delivery work

The public owner must cancel and join capture, text/import/model/index/read/publication producers before receiving erasure. An exclusive media lease does not stop a text producer holding a pre-control snapshot. Next-generation publication ownership, capability and older-client interoperability, recovery/revocation, pairing and explicit review/status UI, bounded resumable transfers, provider cleanup/epoch rotation and real providers/two Macs remain required. Native erasure does not destroy already uploaded ciphertext or offline backups.

F059 remains TODO and all 83 feature statuses remain unchanged. Full native UI/input, sustained physical power, signed/notarized distribution and whole-product parity/ranking remain unverified.

PR #136's separate hosted run passed the full 2,398-method suite with 2,270 passes/128 skips and all three clipboard methods, but its native run failed one of 62 methods with a missing vault-session member. The unchanged vault test passes one local comparison, and a separate three-method native suite-order probe passes under Thread Sanitizer without warnings. Those observations and the fresh local native run do not establish the hosted cause or a fix. The complete failed log and diagnostics remain retained, and no blind rerun was requested.
