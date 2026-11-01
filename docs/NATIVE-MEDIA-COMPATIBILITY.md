# Native media compatibility

An initialized schema-32 collector could drain the deletion queue without the newer exclusive media reservation. A real frozen executable reproduced this: deleting a source and its linked recap in the current library deferred cleanup correctly, but an unrelated import by the waiting older collector removed a reserved PNG and cache and emptied the queue. The reproduction has three retained failing assertions.

Native schema **33** fences this path. Opening an upgraded library with an older executable requires updating that executable. This is an intentional compatibility boundary for physical deletion safety. Original source bodies, IDs, canonical records and conversation formats retain their existing contracts.

## Database boundary

The former `erasure_assets` table becomes a compatibility view over `erasure_assets_v33`. Reading the view requires the current connection function `oswind_media_admission_writer_v1()`. Insert, update and delete triggers preserve queue operations for supported current writers. This read guard matters: the old implementation unlinks a file before deleting its queue row, so a write-only guard would run too late.

Three metadata guards also require the current function. They stop an older initializer that cached the former schema version before migration from rewriting store identity, clearing the dirty marker or committing an old version. Function registration is a cooperative binary capability, not authentication or protection against arbitrary SQL/file mutation.

Current cleanup checks exact view, backing-table and guard definitions before acquiring its reservation and again inside its writer transaction. Missing or modified protection refuses physical cleanup and reports an unknown pending count rather than a misleading zero.

SQLite functions belong to individual connections; persistent triggers and views resolve them there. See SQLite's [application-defined function documentation](https://sqlite.org/appfunc.html) and [trigger documentation](https://sqlite.org/lang_createtrigger.html). Migration drops/recreates the old table name instead of renaming it, so existing queue producers continue to target the guarded view.

## Migration and cache separation

The existing `BEGIN IMMEDIATE` transaction copies pending path bytes, installs the view and guards, transfers the dirty flag to `recap_cache_dirty_v33`, and commits schema 33. No media unlink occurs in migration. The SQLite writer reservation serializes migration with older SQL cleanup transactions. Current cleanup still needs the exclusive media reservation after opening; migration can preserve an already-active shared reader.

Current search graphs use `indexes-v33`. An older worker that already committed its SQL cleanup may still remove its old `indexes` folder afterward; it cannot remove the new namespace through that legacy cache path. Current authorized cleanup removes both namespaces. All caches remain disposable and rebuildable.

Cancellation before commit rolls back the queue, marker and schema. Cancellation after commit returns the committed library with pending cleanup. Upgrade callbacks expose queue-copy, before-commit and after-commit phases for deterministic cancellation/process-death tests; callers must not reenter the opening library.

## Verification in progress

The focused debug run passes **18 methods**, with one subprocess-only helper skipped. It includes two actual already-initialized prior32 collectors, ten fresh-command refusals across two publication/erasure fixtures, queue/schema corruption controls, migration rollback and cancellation, cached statement invalidation, and three real SIGKILL recovery cases. The exact older executable hash is `ce600b7d4c74eaaba65db61050b9b369a05352a9fe80c145e7a438448e01e6e2` from source `36a0e66b71133b032cbcf435e01fbfa86e1a68b1`.

The frozen schema32 migration fixture was produced by that real executable and its native deletion triggers. Its provenance records source/body/media custody; it is never relabeled from current code. Read-only independent inspection of all three killed databases includes WAL, preserved identity/source/queue bytes, original PNG, SQLite integrity and foreign keys. The postcommit WAL contains the new schema; precommit unflushed pages need not produce WAL frames. Main database and WAL hashes remain unchanged by review; volatile SHM marks are excluded.

CI retains these owned crash snapshots and runs a separate Python reader:

```sh
OSWIND_TEST_NATIVE_MEDIA_RETAIN=/new/owned-crashes swift test --filter NativeMediaMigrationTests
python3 scripts/review-native-media-migration.py --root /new/owned-crashes --output /new/review.json
```

Full debug, sanitizer, optimized, package and owned native qualification of schema33 remain pending. Prior schema32 receipts describe their own frozen sources and are not promoted to this version. No sustained-capture, power, storage-power-loss, native-input, distribution, complete-sync, parity or competitive-rank acceptance follows from these tests. F059 and all other feature statuses remain unchanged.
