# Resuming committed file cleanup

This component has source-bound software/native/package qualification. Its earlier focused runs remain exploratory evidence, separate from the current receipt. Whole-product acceptance and release distribution remain open. The previously qualified [cleanup worker lifetime](CLEANUP-LIFECYCLE.md) and PR129 artifacts stay frozen.

Two original owned tests showed the missing behavior: deleting a source while a supported writer held a shared reservation committed logical erasure and kept the file safe, but releasing the writer did not resume the durable queue. Both tests failed without a manual retry; unrelated older history stayed intact.

## Behavior

An active library observes advisory macOS notifications for committed cleanup and supported shared-writer release. Names contain only filesystem device/inode identity, without paths or captured content. Hints do not authorize deletion. Each actual attempt validates the current root, native schema33, durable queue and an exclusive media reservation. Generic cleanup rechecks wipe ownership after obtaining that reservation.

The retry API only finishes already-committed media/cache erasure. It does not apply retention, inventory orphan files, compact storage or complete an unfinished library wipe. The wipe retains its own explicit retry. Supported completion notifications update its pending warning without taking over its work.

One supervisor owns its actual detached worker and every backoff sleeper. Writer conflicts use250ms,1s,4s,15s then30s backoff. Release hints can wake a long backoff, with a250ms minimum between attempts to bound notification bursts. While idle, this scheduler keeps observers and creates no repeating timer or queue probe; separate retention maintenance remains independent. Startup/wake performs a fresh probe; missed release/process-exit notifications recover through pending-only backoff. Structural errors stop repeating backoff. Wake/reopen or an explicit local retry can recheck the problem.

Retirement, lock, switch and plain Quit cancel and join the real supervisor/worker/sleeper, including an attempt waiting before SQLite. Cancellation after actual cleanup preserves its committed outcome and suppresses a retired completion. Wipe waits for this worker before beginning its own operation. Quiet prepared libraries do not start this service as a side effect of wiping. A failed observer setup is visible and retryable after the underlying issue is repaired; retirement/close revokes restart.

Storage settings show waiting/error state without an animated waiting spinner. Earlier deletion/maintenance summaries describe the files queued at commit, while background state reports current work. Background file cleanup finishes earlier deletions independently of the retention setting.

## Source-bound qualification

Source `2818215` binds the [1,363-input receipt](../benchmarks/pending-media-scheduler-v1.json). Full debug: **2090pass/105skip**; selected sanitizer: **843pass/47skip**, no race warning; selected optimized: **843pass/47skip**. All **149 mandatory methods** pass in every build. All **30 package/process stages** and **43 owned native methods / no skips** pass. Full plus native covers **2131 distinct methods**. Independent review verifies every byte of34 app/ZIP/extracted files, strict ad hoc signatures, three retained migration crash states and44 unchanged prior app trees.

Updated supported writers emit these notifications. Older native33/raw SQL producers may not signal; their durable work recovers at startup/wake/explicit retry. Immediate idle discovery from such a producer is not established.

## Exploratory verification

The focused run defines66 cases:63 pass and three explicitly skip (child-only helper and two native cases). It includes21 new ordinary component methods; final cancellation hardening adds one more control. Coverage also includes existing deletion/maintenance lifetime controls, wipe and calendar reconnect. Checks cover actual queue cleanup and unrelated-source preservation, idle zero-probe behavior, bounded release bursts, source admission/root/symlink safeguards, wipe ownership and supported warning recovery, real worker drain, canceled drain caller, backoff cancellation, committed-result retirement, real Quit delegate and library switch.

A separately launched owned process holds a real shared reservation. Its normal release wakes cleanup before a10-second backoff; its SIGKILL exit is recovered by pending-only backoff. The helper validates its temporary UUID root and owner marker and never uses a personal library. Two additional encrypted-APFS session cases pass without skips: lock waits with the image mounted before SQL admission and after actual cleanup commit, then normally closes/detaches and unlocks with the unrelated source preserved.

Initial unsafe-path fixtures were correctly rejected by source admission. Corrected fixtures first admit an ordinary file, then replace it before cleanup; the original admission guard is unchanged. These fixture failures remain separate from the two genuine missing-resume regressions.

## Remaining acceptance

The source-bound component checks above pass. Broader acceptance remains open. Native input/TCC, sustained capture/physical power, actual providers/two Macs, distribution/notarization, complete sync, collection epochs and other worker categories remain open. PR128's separate hosted canceled-unlock busy failure is unresolved; PR129 hosted validation is tracked separately. Native schema and wire formats are unchanged. All83 feature statuses stay unchanged; no parity or ranking claim follows.
