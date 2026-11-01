# Cleanup worker lifetime

Deletion and retention maintenance now own both their detached worker and actor completion. A library departure cancels them and waits for both, including a worker that has not yet reached SQLite or acquired a media reservation. Plain Quit participates in the same drain. Retired or closed models reject queued manual cleanup, deletion, service startup and housekeeping configuration.

The original owned-fixture reproduction had four cases and twelve failing assertions: an exit drain could return while the unowned worker later deleted data, and retired models still accepted manual deletion/maintenance. Separate regressions showed obsolete retention settings deleting a source after automatic retention was disabled or the retention window changed, stale source/search/answer previews surviving cancellation after a real commit, and timers reappearing on retired/closed models. All original failures remain retained in their own logs.

## Cancellation boundaries

A drain prevents new destructive work until its current workers and completions finish. Cancellation of the drain caller does not acknowledge unfinished work. A worker canceled before SQLite admission leaves its source intact. A commit that already happened stays committed; it is never reported as a rollback. A retired completion cannot publish success or start index catch-up in its former workspace.

Privacy-policy changes cancel maintenance using its captured policy, even if saving the new settings fails. Turning automatic retention off cancels automatic maintenance; an explicit manual cleanup remains separately authorized. Reopening onboarding suspends automatic cleanup. Reconfiguring an already-enabled timer does not cancel a permitted in-flight job. Native retention cancellation remains cooperative and preserves already-committed work.

When cancellation follows a committed removal in the current model, source-derived answer/draft/tool/clipboard state is invalidated. Cached selection/search/chat references are dropped locally instead of starting fresh IO from the canceled completion. The actual committed count is retained in the status. Ordinary successful completion can refresh the surviving graph normally.

## Verification in progress

Owned actor tests cover direct drain, a canceled drain caller, pre-launch retirement, closed roots, real plain Quit, library switch, before-SQL cancellation, after-commit cancellation, stale UI state, current retention settings, failed settings save and queued timer/service startup. Existing deletion, startup maintenance, import, conversation and workspace-wake controls are included. Preliminary focused coverage passes111 defined cases:96 passed and15 explicitly skipped.

Two owned encrypted-APFS session cases pass without skips: a real lock waits while an actual unreserved deletion/maintenance worker is held, the image stays attached until release, normal locking then detaches it, and unlocking preserves the canceled source. Full source-bound software, sanitizer, optimized, native41 and fresh package/independent archive qualification remain pending.

## Separate hosted vault failure

PR128 hosted run41360031490 passes its full2141-method suite (2038 passes/103 skips) and benchmark harnesses. Its separate39-method encrypted-volume stage fails canceled-unlock recovery with hdiutil exit16 (busy):38 pass and one fails. The failed case had no stage-specific trace in its retained diagnostic artifact. Local native passes do not resolve that hosted failure, establish its cause or justify forcing a detach.

The cancellation fixture now uses the existing bounded, owned-root-only native observer with explicit cycle/stage labels and credential-redacted success/failure persistence. An initial traced local execution passes five cancellation/recovery cycles with136 observed native calls and no nonzero result. No production detach retry, timing, permission, indexing or force behavior is changed. Further captured failure evidence is required before claiming a causal fix.

## Remaining scope

This work does not implement the pending-media cleanup scheduler. Automatic coalesced resume after reservation release, supported cross-process notification/backoff, idle behavior and scheduler lifecycle remain required. Complete sync F059, other worker categories, collection epochs, native input, sustained capture/power, actual providers/two Macs and notarized distribution remain open. Native schema33 and wire formats are unchanged. All83 feature statuses remain unchanged; no product parity or competitive-rank claim follows.
