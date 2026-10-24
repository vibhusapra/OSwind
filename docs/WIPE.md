# Full-library erasure and recovery

Delete all local memories now runs off the main thread and reports what committed separately from unfinished file cleanup. It removes sources, linked recaps, conversations, routines, routine history and search vectors. A durable inventory includes retained images, audio and replay files that no longer have source rows. Provider keys, settings, downloaded models and externally saved exports/backups remain.

The native action stops capture, audio, API access, scheduled routines and in-flight note/import/answer/index work. Capture-on-launch, API and scheduler settings are turned off. Busy guards prevent another native wipe or new capture/import from racing it. Progress, Stop cleanup and Retry library cleanup are available in Data settings. Pending cleanup remains visible after reopening the app. Store initialization does not synchronously drain an interrupted wipe, and automatic services/maintenance wait for its cleanup; explicit native retry runs in the background.

## Commit and cleanup

1. Wait for supported media writers to finish retaining and admitting their files. Database reads and ordinary text writes can continue while this reservation waits.
2. Reserve the SQLite writer and stream the three retained-media buckets into the durable deletion queue. Inventory is descriptor-relative, bounded in directory depth and does not follow symlinks. No file is deleted before the database transaction commits.
3. Delete all recorded history and rotate search identity in that same transaction. Cancellation or failure before commit rolls back history and queue admission.
4. Drain the queued files, preserve any newly live shared references, remove empty media subdirectories and compact the database. A file-access failure, unsafe member, held reader or cancellation becomes a pending outcome rather than a false claim that the history was untouched.

A persistent completion marker covers unfinished files, disposable indexes, empty-directory cleanup and database compaction. Retry drains only the sealed queue; it does not rescan and sacrifice newly recorded orphan files. File contents and counts are checked in owned process fixtures, including new live references reusing a previously queued path.

An active reader can retain old WAL pages even after logical deletion. The result explicitly reports unfinished compaction; close other readers and retry. Stopping cleanup after commit returns the actual erased counts and leaves outstanding files queued. Removing invalid symlinks manually and retrying does not follow or remove their targets.

The library directory identity is pinned. A replaced root is refused before inventory; a replacement detected after commit leaves the old library's files queued and preserves the replacement folder. Reopen the intended library to finish cleanup. Arbitrary malicious filesystem mutation is outside the cooperative protocol.

## Media admission and compatibility

Schema 16 introduces a private cross-process media admission lease. Screenshot retention, audio admission and replay's final retained-file copy hold shared leases until the source has been admitted or its new files discarded. Full wipe and its retry take an exclusive lease before any store/SQLite lock. This prevents inventory from erasing a supported writer's file just before that writer admits it.

The public `mediaWriteLease()` supports custom media producers. Raw manual file writers must opt into this protocol. Fresh older executables refuse the upgraded schema; already-open old processes and arbitrary raw SQLite/file writers are outside the admission guarantee. This does not globally stop another client's later text writes. The deletion transaction defines the cutoff: writes admitted after it are new history and remain.

`deleteAll()` remains available and returns `LibraryWipeResult`; use its `erasure`, conversation/routine counts, `compacted`, `cleanupComplete` and `cancelled` fields to present an accurate outcome. Precommit failures throw; postcommit cleanup failures return a result with warnings and pending work.

```bash
oswindctl wipe --confirm DELETE-ALL --json
oswindctl wipe retry --json
```

The CLI validates confirmation and options before opening the library. It reports progress on stderr and the final result on stdout. Ctrl-C before commit exits 130 with history preserved. After commit it returns the actual result with `cancelled: true`; a second Ctrl-C forces exit. A killed process leaves durable queued work for a later retry. The CLI does not remotely stop another running app's capture; pause other clients when an empty library is required.

## Evidence and boundaries

[Machine-readable evidence](../benchmarks/library-wipe-v1.json) records exact source/binary/package identities, normal and ThreadSanitizer suites, older-writer refusal and process regressions. Owned fixtures test referenced/orphan media, favorites, recap dependencies, symlinks, root replacement, busy readers, writer contention, native status/retry/service shutdown, SIGINT and SIGKILL. These are separate from native click/focus/accessibility acceptance, which remains pending while the Mac is locked.

This is logical library erasure with retryable file cleanup. It is not secure SSD wiping, removal of external copies, a storage power-loss test or competitor performance evidence. Broad feature parity, encrypted vault/migration, natural capture/power and continuous 24-hour completion remain open.
