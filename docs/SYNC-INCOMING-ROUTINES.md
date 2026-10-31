# Incoming recipes and run history

Tested internal adapter on `codex/sync-incoming-routines`; run-specific process-death and throughput gates remain open. F059 remains TODO. This adds internal typed adapters; it enables no pairing, transfer service or automatic peer execution. The schema-28 [incoming-source receipt](../benchmarks/sync-incoming-sources-v1.json) covers its frozen parent implementation, not this schema-29 work.

## Behavior

| Data | Native receiving behavior |
| --- | --- |
| Recipe | Copy the portable title, prompt, schedule and source window. Use local AI defaults; disable the recipe and remote processing. Device-specific model names, endpoints, credentials and scheduler activation are excluded from the wire record. |
| Recipe edit | Retain exact older definitions. Increment the native editor revision; keep the received recipe disabled. Final admission checks the native payload, SQL activation flag, revision and next occurrence. |
| Run | Record history without claiming an execution slot or invoking a provider. A peer's `running` status projects to native `interrupted`; its original status stays available as attribution. |
| Original recipe | Retain the exact referenced definition separately from the editor's current recipe. An unavailable original remains explicitly unavailable. Never substitute today's prompt for an older run. |
| Run update | Preserve the immutable recipe reference, original editor and ordinal while updating the admitted run status and result link. Retain prior exact wire versions. |
| Local correction or deletion | Clear stale run attribution and cached wire versions when canonical fields change; deleting the native run cascades to its original. |
| Quiet backup/restore | Validate and preserve run attribution, native frames and exact recipe bytes. Restore scheduling off and omit the sync journal/catalog. A later fresh catalog remaps current object lifetimes without claiming that its current recipe is the old definition. |

Native run history displays the original title when available and labels the recorded status and recipe revision. The receiving run uses a local revision binding; its original editor/ordinal remain separate data.

## Storage and admission

Schema 29 adds `routine_run_originals`, a bounded canonical data-only record with the exact portable run, optional exact recipe definition and SHA-256 of the complete eleven-cell native run frame. The existing native capture/projection frame stays eleven cells, preserving queued schema-28 frames. Same-transaction peer admission uses a connection-owned, exact-frame permit and an exact original-payload permit. Both SQLite functions are non-deterministic, default-deny and clear on return or throw.

Run updates preserve old cached versions only inside that scoped admission. Ordinary local changes retain existing privacy invalidation. Immutable original rows cannot be independently changed or dropped while their matching native owner remains unchanged. Forty-five compatibility guards fence canonical, historical and new original rows from older writers. Exact older cache-trigger SQL migrates; missing or altered current protection refuses. The existing limited derived-pin repair remains supported.

The shared final typed dependency/head audit and a final native/original comparison run after mutable callbacks. A released/foreign library reservation, late mutation, missing owner, stale dependency, conflicting local owner or changed original recipe must refuse and roll back native rows, original metadata, versions and journal state together.

## Evidence and open gates

The [public validation receipt](../benchmarks/sync-incoming-routines-v1.json) records 25 passing stages: 1,561 full/default passes with 77 explicit skips, 429 sanitizer passes with 15 skips and no race warnings, and 429 optimized passes with 15 skips. Fourteen new cases cover the recipe/run and migration boundaries. Actual schema-28 fixtures with and without an installed version cache retain their producer and database hashes beside the SQLite resources.

An independent readonly reader checks actual producer packets, both retained run versions, the exact old recipe definition, current editor revision, eleven-cell native frame, timestamps, writer fences and no outgoing echo. Seven corruption controls refuse, including an original retarget with recomputed references. Both SQLite files remain unchanged.

Fifteen staged-package stages pass: SDK, normal/indexed HTTP/MCP, erasure/deletion/retention/wipe/recap/backup interruptions, actual old28 client refusal, readonly old27 historical archive/quiet restore, and actual run-original backup/restore/deletion. All 34 ZIP files match the staged app and both strict signatures pass. The installed app's 15 files remain unchanged and test fixtures are excluded.

All 439 tracked source/test inputs are identical across builds and process gates. There are 686 common tracked repository inputs; the [final 687-file manifest](../benchmarks/sync-incoming-routines-inputs-v1.json) also includes the corrected capture smoke harness. Its schema assertion edit accidentally changed accounting `128` to `129`; corrected affected CLI stages pass under their own manifest. The full/TSan/optimized code needed no change. Development-v10 retains the real quiet-restore/re-export failure fixed by reconstructing mapped native packets. Two unused SQLite runtime sidecars are excluded from portable counts; their raw snapshot hashes remain recorded. All earlier attempts and frozen private logs remain under `.artifacts/sync-incoming-routines-v1/`.

- [x] Real outgoing-to-journal-to-native recipe/run fixtures, disabled local configuration and no outgoing echo.
- [x] Exact old recipe retention, run status projection, native SQL activation refusal and late native mutation rollback.
- [x] Restart, quiet restore, local mutation cleanup, independent deletion refusal and connection-permit cleanup tests.
- [x] Actual schema-28 native/cache fixtures and missing-current-protection refusal.
- [x] Corrected fresh-catalog re-export broad regression and full/default test suite.
- [x] Frozen sanitizer/optimized checks, independent original/native/wire review and corruption controls.
- [x] Staged signed package/process checks, actual old28 client refusal and quiet old28/current29 portability.
- [ ] Run-update process-death gates and an authored bounded throughput comparison.
- [ ] Complete entity/correction/deletion adapters, current privacy/erasure epochs and safe media staging.
- [ ] Production lifecycle/service, enrollment/recovery/conflict UI, encrypted provider transport and actual two-Mac acceptance.

No current product ranking, native screen/audio capture, physical power, cold-cache performance, provider inference or distribution acceptance is established by these fixtures. All 78 feature statuses remain unchanged.
