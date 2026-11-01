# Media cleanup admission and backup erasure fencing

A supported media writer or visual snapshot holds a shared reservation while its files are in use or await database admission. Opening the library, deleting one source, scoped erasure and retention now preserve those files until an exclusive cleanup reservation is available. Logical deletion still commits immediately: removed sources and their dependent results cannot be used for new admission.

Cleanup attempts under the store SQL mutex never wait for a media lock. A nonblocking exclusive attempt either drains the durable queue or returns committed source counts, pending media, an uncleared cache indicator and a retry warning. Retention stops further storage-budget trimming while cleanup is deferred. Explicit retry uses the same rule. A closed library reports an unavailable pending count as -1, rather than zero. A replacement library folder, shared/foreign/released reservation or open SQL transaction cannot authorize unlinking.

Full-library wipe keeps its existing exclusive reservation acquired before SQL. It passes that exact reservation through cleanup; there is no nested exclusive acquisition. Search state is invalidated immediately, while physical disposable-cache deletion waits with media cleanup. The durable dirty marker survives deferral. Release followed by another invalidation, reopen or explicit retry can drain work; a scheduler that guarantees prompt cleanup under continuous recording is not included.

## Backup publication

Preserving media must not let a backup publish a source erased after its snapshot. Additive schema-32 metadata records an opaque erasure generation. Plain SQLite AFTER DELETE triggers cover memories, historical originals, chat sessions, chat turns, routine definitions, routine runs, run originals and entities. The marker changes in the same transaction as deletion and rolls back with it. No native table column, wire format or schema-version change is introduced.

Backup validates exact trigger definitions and marker shape. A generation change during snapshot construction causes a bounded retry. A retry discards every prior media pin in bounded pages before preparing the new snapshot, so deletion/recreation at the same logical path cannot attach the erased version's pixels to the new source.

Deletion during copying or verification causes final publication refusal. A short SQLite writer reservation covers the final generation check and atomic directory publication, closing the check/rename race across supported SQL connections. Publication callbacks run before that reservation. Ordinary appends do not advance the erasure marker and can continue during a point-in-time backup. Previously published backups remain independent artifacts.

## Verification

The [software receipt](../benchmarks/media-cleanup-admission-v1.json) at `ab571d4` binds 1,330 tracked repository inputs. Full debug: **2,023 passed / 99 skipped / zero failures**. Thread Sanitizer and optimized: **702 passed / 39 skipped / zero failures each**, all **70 mandatory controls** in all three builds, including 19 new methods and two exact frozen prior32 client methods. No race warning is present. One quiet-wake method that previously passed now skips its unlocked-session/thermal admission guard.

Actual CLI erasure, deletion, wipe and backup harnesses pass, including eight competing erase processes, backup/restore checks, and SIGINT/SIGKILL recovery. These are owned process fixtures, not a signed package or native UI qualification. Initial genuine cleanup, backup publication and stale retry-pin failures remain retained; opening-fixture and compiler-cache failures are classified separately.

The [generated scaling receipt](../benchmarks/media-cleanup-scaling-v1.json) starts each scenario with 20,000 authored records and 10,000 small media files. Each operation erases 10,000 sources. Selective apply takes 2.730 s preserving shared files, then 3.403 s deleting them; age-based retention takes 2.680 s, then 3.429 s. Peak CLI RSS stays under 41 MB decimal. All remaining source IDs, media contents and SQLite integrity checks pass. These are single warm observations on M5 Max/128 GiB/macOS 26.6.2 after the agent's test/build jobs finish; uncontrolled caches, thermal/background state and no paired baseline establish no causal improvement, power result or competitor rank.

Controls include opening after genuine recap invalidation, supported writer and actual image-snapshot reservations, separate-process admission, single/scoped/retention/retry paths, rollback, replaced folder, invalid lease authority, unavailable counts, pinned and text-only erasure retries, copy/verification/publication refusal, recreation at the same media path, append-only capture, marker tampering and exact frozen older-client deletion.

## Current app and native qualification

The [native/package receipt](../benchmarks/media-cleanup-native-v1.json) binds 1,334 repository inputs at qualification head `029d169`, with production/test Swift bytes equal to tested native source `ab571d4`. All **27 package/process stages** pass, including **39 owned native APFS/app-session methods with no skips**. Full plus native coverage is **2060 distinct methods**; build repetitions are not added as new coverage. Independent review checks every byte of all 34 app/ZIP/extracted files, strict ad hoc signatures and all 38 earlier app trees unchanged.

The actual packaged CLI preserves an externally reserved PNG/cache during source deletion and reports pending work. After release, cleanup may run as the CLI opens the library, so an explicit retry can correctly report zero additional removals. The original probe's contrary counter assumption is retained as a harness failure; strict pending counts, byte preservation and physical absence remain required.

A separate packaged backup is positively stopped during its copying phase. Another actual CLI process commits source erasure while the backup still holds its shared reservation. On resumption the backup refuses the changed generation and publishes no archive; explicit cleanup then completes. Both read-only fixture databases pass integrity/FK checks with empty source and erasure queues. These authored probes establish process behavior, not desktop/media capture or storage-power-loss acceptance.

Reproduce the public packaged regression with a fresh root:

```sh
python3 scripts/media-cleanup-smoke.py /path/to/OSwind.app/Contents/MacOS/oswindctl --root /new/owned-fixture
```

CI now runs this check against its packaged app and retains the process report. The new hosted run must pass separately. This local package is ad hoc signed; native input, sustained capture/power, notarization/distribution and complete sync remain open.

## Boundaries

This is cooperative current-client software verification. An older executable that removes files without the new exclusive gate, raw SQL/file mutation, already-rendered GUI state, arbitrary immutable-path replacement, secure SSD erasure and storage power loss require separate treatment. The exact older executable can demonstrate plain-SQL generation-trigger compatibility without establishing general held-reader safety for its legacy cleanup code.

The initial software receipt and the later app/native receipt have distinct source bindings. Native GUI acceptance remains open. It establishes no throughput, energy, competitor ranking or product parity result. All 83 feature statuses remain unchanged; complete sync F059 stays TODO.
