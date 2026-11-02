# Native group erasure — internal WIP

`SyncNativeCollectionReceiver` now supplies the required native adapter for a newly authenticated encrypted group-erasure control. It uses the receiver's existing exclusive media lease and SQLite transaction. This is internal infrastructure; no background sync service is enabled.

The adapter retires existing journal registers using their real heads and verified collection frontier, without inventing per-object deletion operations or advancing peer stream cursors. It clears raw capture and staged work through their accounting hooks, stages the actual native library wipe, purges typed/session/recipe/run caches and original projections, retires publication work and bindings, and clears reusable native key frames and bootstrap cursors. Immutable authored headers, receipts, expected successors and lifetime-era fences remain retained.

Received cleanup uses `library_group_wipe_dirty_v1`. It shares pending-cleanup, startup and retry behavior with local library wipes, while avoiding the local-intent SQL hooks. A received erase cannot approve a local wipe or author another local counter. Physical files stay present until the transaction commits; cleanup subsequently touches only sealed queued paths and preserves later media.

Retiring stale publication metadata requires the same group, epoch, capture generation, schema and accounting. A prior local wipe can leave its publishing authority invalid; authenticated erasure may clear that metadata without granting fresh publishing authority. Ordinary publication still refuses the invalidated queue.

## Current evidence

- Current focused preflight: **23 passes / one explicit owned-worker skip**, including all 14 local/staged wipe tests, actual 13-kind retirement, raw and staged work, original projections, completed publication bindings, a native archived original, transaction/lease refusal, rollback/retry, later identities and older controls.
- An earlier candidate related run passed **693 methods / 36 explicit skips**. The later transaction/key-retirement guards have focused evidence, pending the full final-source runs.
- Independent readers inspect seven consistent SQLite/media snapshots, closed native-original and completed-binding fixtures, the local-clear regression, and actual database/WAL files retained after SIGKILL immediately before and after commit. Database integrity and foreign keys pass. Headers and peer cursors remain unchanged; no local erase echo is created.
- The original candidate refused group erasure after a local wipe invalidated publication authority. Its two failed assertions, source snapshot and fixed regression remain retained. Initial crash-parent failures came from strict inspection through macOS's `/var` alias; POSIX `realpath` corrects that fixture path while retaining read-only/no-follow flags. An independent-reader attempt also retained its failure before a fresh baseline explicitly accounted for newly created empty coordination WAL files.

These are preflights, not a completed final-source/software/package qualification. Frozen successful readers are not rerun or relabeled as later source acceptance.

## Remaining delivery work

The public owner must cancel and join capture, text/import/model/index/read/publication producers before receiving erasure. An exclusive media lease does not stop a text producer holding a pre-control snapshot. Next-generation publication ownership, capability and older-client interoperability, recovery/revocation, pairing and explicit review/status UI, bounded resumable transfers, provider cleanup/epoch rotation and real providers/two Macs remain required. Native erasure does not destroy already uploaded ciphertext or offline backups.

F059 remains TODO and all 83 feature statuses remain unchanged. Full native UI/input, sustained physical power, signed/notarized distribution and whole-product parity/ranking remain unverified.

PR #136's separate hosted run passed the full 2,398-method suite with 2,270 passes/128 skips and all three clipboard methods, but its native run failed one of 62 methods with a missing vault-session member. The unchanged vault test passes one local comparison; that does not establish the hosted cause or a fix. The complete failed log and diagnostics remain retained, and no blind rerun was requested.
