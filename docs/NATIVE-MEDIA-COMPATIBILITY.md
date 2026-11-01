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

## Qualified component

The [source-bound receipt](../benchmarks/native-media-compatibility-v1.json) binds **1,346 inputs** at `fe54050`. Full debug: **2,042 passed / 99 skipped / zero failures**. Thread Sanitizer: **755 passed / 40 skipped / zero failures**, with no race warning. Optimized: **755 passed / 40 skipped / zero failures**. All **88 mandatory controls** execute in all three builds, including four exact frozen prior32 methods: two initialized collectors and ten fresh-command refusals across two publication/erasure fixtures.

Optimized source `14c2a92` retains its own binding. Every native, test, package and runtime input is byte-equal to `fe54050`; the sole difference is final owned SQL inspection registration in `scripts/erasure-smoke.py`. The complete corrected erasure CLI harness is freshly executed. All four erasure, deletion, wipe and backup process harnesses pass.

The exact older executable is `ce600b7d4c74eaaba65db61050b9b369a05352a9fe80c145e7a438448e01e6e2`, produced at `36a0e66`. The frozen schema32 migration database was produced by that real executable and its native deletion triggers. Its provenance preserves source/body/media custody; it is never relabeled from current code. Queued byte paths, source identity and bodies survive migration. An earlier SQL writer must finish before the migration copies its newly committed queue entries.

Three actual SIGKILL snapshots are retained before product reopen. Separate read-only SQLite inspection includes WAL, original PNG, identity, source/queue counts, dirty marker transfer, integrity and foreign keys. Precommit unflushed pages need not produce WAL frames. Main database and WAL bytes remain unchanged by inspection; volatile SHM marks are excluded. Reopening recovers the whole committed state and completes cleanup. CI retains the snapshots and runs this independent reader:

```sh
OSWIND_TEST_NATIVE_MEDIA_RETAIN=/new/owned-crashes swift test --filter NativeMediaMigrationTests
python3 scripts/review-native-media-migration.py --root /new/owned-crashes --output /new/review.json
```

All **30 app/package/process stages** pass, including **39 owned native APFS/app-session methods with no skips**, actual packaged media reservations, concurrent backup-erasure refusal and an actual prior32 compatibility process. Independent review checks every byte of all **34 app/ZIP/extracted files**, strict ad hoc signatures and all **40 prior app trees unchanged**. Full plus native coverage is **2079 distinct methods**; repeated builds are not added as new coverage.

## Retained failures and acceptance limits

The original reserved-PNG/cache loss has three genuine failing assertions. Initial migration WAL-bootstrap/empty-scalar harness mistakes, stale schema/cache expectations and raw-reader function omissions remain retained separately. One real 40-second calendar timer expectation expired during a concurrent full run. The exact isolated method then passed without a source/timeout change, and the fresh full run passes it at30.066s before sanitizer starts. That timing-sensitive failure is preserved, rather than suppressed or reclassified as a passing run.

This is a cooperative native compatibility boundary. It does not authenticate peers or prevent arbitrary SQL/filesystem mutation, revoke an already-rendered old GUI, or establish storage power-loss safety. The app is ad hoc signed. Native input/TCC, sustained capture/power, notarization/distribution, actual providers/two Macs, cleanup scheduling/lifecycle and complete sync remain open. F059 and all other feature statuses stay unchanged. No feature-parity or competitive-rank claim follows.
