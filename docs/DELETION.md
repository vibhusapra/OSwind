# Shared-media deletion and retention

Schema 14 routes individual deletion, time retention, storage-budget trimming and selective erasure through one durable media queue. Previously, individual deletion unlinked a source's paths immediately, even if another source still used the file. Retention called that unsafe path for every expired row. Both failures are retained in the regression evidence.

A SQLite before-delete trigger admits image, audio and replay paths to the queue in the same transaction as source deletion. This covers direct SQL source deletion too, though direct SQL callers must explicitly request physical cleanup. The application and CLI perform cleanup after their deletion commits. Matching live canonical paths preserve shared files, including dot and case aliases; separate hard-link directory entries remain independently removable. Unsafe paths, symlinks and directories are refused, and failed files stay queued for retry.

## Clear outcomes

`MemoryStore.delete` returns `HistoryErasureResult`: committed source/answer counts, removed/shared/pending media, cache outcome and warnings. It does not report that nothing happened when source deletion committed but a file could not be removed. The native app runs this off the main thread and shows progress/result status. Other deletion/cleanup actions are disabled while one is running.

`pruneHistory` returns a detailed retention result with the erasure report, remaining bytes, optional target, target-met flag and cancellation state. The earlier `prune` API remains a count-only compatibility wrapper; use the detailed method when presenting outcomes.

- Age retention deletes all expired sources in one transaction, then scans surviving media references once for that cleanup, rather than scanning the archive once per source.
- Storage cleanup removes disposable search files before sacrificing recorded evidence. It then deletes oldest-first batches of at most 16 sources, drains media and compacts before measuring storage again. A batch may remove more sources than the smallest possible set needed to meet the target.
- Pending media or failed cache removal stops further destructive budget trimming. A target that cannot be reached is reported explicitly; unrelated history is retained.
- Cancellation before the first commit rolls back. Cancellation after a committed batch returns the actual partial result and keeps the remaining history. Tests exercise cancellation after exactly 16 committed removals.

Search identities and disposable indexes are invalidated on public erasure. Search can use a correct fallback while indexes rebuild. Tests retain direct-SQL stale-index validation, and separately require public-erasure invalidation followed by successful ANN/Metal recovery. Incremental private cache compaction and a faster validated asset-reference projection remain performance follow-ups; individual deletion still scans surviving media references.

## CLI

```bash
oswindctl delete SOURCE_ID --json
oswindctl prune --days 30 --max-gb 20 --json
oswindctl erase retry-media
```

Without `--json`, the existing terse output remains, with cleanup warnings on stderr. Invalid/duplicated numeric options now fail rather than silently defaulting to destructive retention settings. Delete/prune commands avoid loading an unused embedding model.

Opening a schema-13 library installs the queue trigger and upgrades it to 14 without changing source identity. Older executables refuse the upgraded library. A real pinned prior build was exercised: its attempted deletion failed without changing the database bytes. Already-open old processes and arbitrary manual SQLite access are outside that refusal proof. Backups/restores continue to use the current trusted schema and start quietly.

## Evidence and remaining gates

[Machine-readable report](../benchmarks/unified-deletion-v1.json) records source/binary pins, failures, process contracts and scale results. The final normal suite passes **419 cases / six opt-in skips (425 total)**. Focused ThreadSanitizer passes **57 cases** on the same backend and controller concurrency, before a copy-only singular/plural label correction. The final normal suite exercises the corrected copy.

The generated age-retention trial has 20k sources and 10k tiny shared media files. One half is old and one future-dated; after the first pass, the remaining sources are deliberately aged outside the timed operation for the second pass. Every surviving source ID, media filename and shared-file byte string is checked. This does not measure storage-budget scale, natural screenshots/audio, power, faults or competitor performance. Full backup/interruption, selective-erasure/eight-writer, query/Ask and routine process regressions pass on the installed release.

Light/dark renders use real controller operations on owned synthetic libraries. Native click/focus/accessibility acceptance remains pending while the Mac is locked. This is logical live-history deletion, not secure SSD wiping or removal of external copies. Earlier independent saved recap copies remain a separate provenance gate. Whole-library wipe failure UX, large-archive migration/individual-delete costs, vault/migration, natural capture/power and independent competitor acceptance remain open.
