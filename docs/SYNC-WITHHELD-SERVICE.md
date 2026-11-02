# Privacy holds, network pause and native renewal — internal WIP

This checkpoint extends the folder-backed service across the same 13 native kinds. It does not enable public sync. F059 remains TODO.

## Behavior

- Privacy denial rolls back the owner's tentative typed graph before acknowledging ordinary work. Only opaque owner/dependency digests and policy metadata enter a bounded durable hold. Explicitly denied source content is checked before staging its media. Tentative journal and cached graph-body writes roll back; permitted rows behind that owner can proceed. Filesystem staging is separate from SQL rollback: independently permitted encrypted chunks may remain in the local spool, whose selective garbage collection is still open.
- A native edit wakes its owner and dependent holds. A saved privacy/media policy change reviews metadata in keyset pages with a persisted high-water ordinal. Reparked records and new arrivals cannot extend that review indefinitely. Closing and reopening the library preserves both holds and an in-progress review.
- Held local edits cannot be overwritten by incoming ordinary projections, including indirect native SQL mutations. Authenticated deletion uses a connection/thread-scoped capability to retire held descendants. The capability clears on error and cannot be borrowed through another connection. An independent held private metadata conflict remains a conflict after source/answer erasure; it is not silently discarded.
- Network pause cancels and joins the current worker, then continues local preparation without provider I/O. Resume joins the local-only worker before restarting delivery. Stop remains terminal; old worker generations cannot publish late status. Existing review handoffs remain waiting instead of restarting automatically.
- Metadata quota refusal rolls back the owning batch without acknowledging unretained holds. The scheduler reports retrying storage rather than terminating. This preserves work; it does not establish progress under permanent storage exhaustion.
- Native publication renewal requires the exact completion digest stamped only after the native retirement path finishes. Cleanup is checked inside the renewal transaction. The completion is consumed atomically with the new publication lifetime. SQL frontier triggers invalidate it even when an older writer bypasses the current Swift observer; absent or changed protection refuses. A generic group receipt cannot impersonate native completion. Old queue objects remain invalid after renewal.

## Remaining product gates

Public create/join/recovery and status/conflict UI; actual app capture/import/model drain through Quit/switch/lock/wipe; per-device signing, membership/revocation and external rollback authority; complete older-client fencing; cold offline startup; raw capture overflow and disabled/recreated-row reconciliation; assigned immutable outbox versions newly denied by policy; resumable large graphs outside long writer transactions; selective encrypted-spool GC and backup semantics; provider/two-Mac/native/power/distribution acceptance.

The prior schema 33 compatibility test inserts an explicitly synthetic completion sentinel to exercise installed SQL invalidation. It does not claim that the old executable can produce authentic native completion. Two local library fixtures do not establish two-Mac acceptance. Scheduling intervals are not battery measurements.

An ordinary debug CLI wipe of a copied fixture covering all 13 kinds, containing one explicitly synthetic valid hold and review cursor, clears native records, cached bodies, originals, holds and review state. Twenty-one body-free deletion intents remain across 13 native kinds; they retain only opaque 32-byte before keys. The first reader incorrectly expected zero intents; that failed assertion is retained, and the already-successful wipe was not rerun.

A separate actual frozen prior schema 33 executable refuses opening and writing an owned copy with the installed hold schema because it lacks the new SQLite function. The current debug executable writes successfully. This incidental fail-closed result is not a supported upgrade UX or evidence that an already-running older client is fenced. Native schema remains 33; explicit compatibility work is still required before public activation.


## Baseline source-bound software verification

Source `e79120f` binds [all 1,444 tracked inputs](../benchmarks/sync-withheld-service-inputs-v1.json) and the [software receipt](../benchmarks/sync-withheld-service-v1.json). Full debug: **2,315 passes / 125 skips**. Selected Thread Sanitizer: **1,255 passes / 71 skips**; optimized: **1,255 passes / 71 skips**. All **474 required methods**, including **29 service/renewal/hold cases**, and **19 additional owner-qualified backend controls** pass in each mode, with no sanitizer race warning. Both frozen CLI paths are supplied in every original runner; the five compatibility methods pass there without supplements.

Independent immutable readers inspect three reopened-library fixtures: all 13 native kinds, 21 byte-identical wire bodies, native/historical-original citation joins, cursor 21, one completed native answer binding and zero receiver echo. This remains software verification. It includes no new app/native APFS package, physical provider/two-Mac, power, distribution or whole-product parity/ranking acceptance. The earlier source `92b9a84` qualification stays frozen.

[The completed hosted run](../benchmarks/sync-library-service-hosted-v1.json) qualifies published head `899d1a6`, whose runtime is source `92b9a84`: full 2,295 passes/129 skips, native 62 and named clipboard 3 without skips. Its actual merge checkout tree equals the published head and all 81 native-job steps succeed. It does not qualify source `e79120f`. PR136's separate missing-session failure remains causally unresolved.

## Worker ownership follow-up

Source `dd68dfa` changes only `SyncLibraryScheduler.swift`: the old worker remains registered while network reconfiguration awaits its join, allowing a simultaneous Stop to join the same task. [All 29 service cases pass in debug, Thread Sanitizer and optimized builds](../benchmarks/sync-scheduler-join-v1.json), without skips or race warnings. [The follow-up input manifest](../benchmarks/sync-scheduler-join-inputs-v1.json) binds all 1,444 tracked files. Three new independent readers verify its reopened fixtures covering all 13 kinds. These targeted results do not reclassify the predecessor's 474-method full/selected runs as current-source runs.

The task-slot fix is reviewed in the code delta; no new deterministic simultaneous Stop/pause race oracle or app-wide capture/import/model shutdown acceptance is claimed. Supplemental ordinary CLI wipe and frozen-client probes above were performed at predecessor `e79120f`, whose native/CLI code is unchanged by this scheduler-only delta.
