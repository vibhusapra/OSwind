# Import input and worker lifetime

Normal JSON imports now check a selected regular file's size before allocating its full contents. JSON retains its 100,000,000-byte limit; saved Limitless responses retain their existing smaller limit. Reads use one retained descriptor, fixed-size chunks, cancellation checks and final file/folder identity and metadata checks. Symlinks, directories, FIFOs, non-file URLs and remote file hosts refuse. Input bytes and paths do not enter error messages.

This does not make accepted imports constant-memory: the bounded input and decoded records still occupy memory. A regular-file read, Foundation decode or one Apple embedding call can delay cooperative cancellation. No forced close or detach bypasses unfinished work.

## One reservation, then a joined close

Configured GUI and CLI operations acquire shared library activity before input reading and saved-settings capture. Collector CLI stdin is included, with its existing 30-second input deadline. JSON, collector and Limitless core entrypoints cover decoding too. Nested calls borrow the same reservation rather than reacquiring shared file locks, which could otherwise interact badly with a waiting exclusive operation. Exclusive operations can report busy until pending input finishes, is cancelled or reaches its existing deadline.

The caller owns an explicitly supplied `admission:` reservation. Imports check its library/active state at entry, take its state mutex before SQLite and hold it through final commit. This matches audio/visual writer ordering. Waiting for a shared reservation leaves SQLite available to other work. A wrong-root, released or prematurely released reservation refuses; late refusal rolls back the batch. A successful import does not release a borrowed reservation. Settings are checked before input/decode as well as at publication. [Record/settings transaction checks](IMPORT-PREPARATION.md) remain in force.

The GUI retains both the detached worker and UI completion task. Cancel and privacy changes reach the actual worker directly, including when saving new settings fails. Library departure removes visible access, cancels work, and joins both tasks before SQLite close or encrypted detach. A worker paused before it has acquired any reservation must join too. Plain-library quit uses the asynchronous termination path while an import is pending. Cancellation of the drain caller does not acknowledge early completion.

Switching ordinary libraries also fixes an existing bug: two absent vault packages compared equal, so opening any other ordinary library returned without switching. The same-vault shortcut now requires an actual vault package. An invalid destination is validated before departure and preserves the current model and import.

Other application workers and complete native window/permission acceptance retain their own existing gates; this is an import drain, not a claim that every app operation is joined at plain quit. Learned PII capture/import/egress is still off.

## Evidence and reproduction

Corrected product source `94f60b0abef6c58faa53cfd8ce3271f4bffe0b5e`, [draft PR #83](https://github.com/vibhusapra/OSwind/pull/83). [Frozen qualification](../benchmarks/import-input-lifetime-v1.json): **1,164 defined / 1,162 passes / two skips**, **119 selected TSan passes**, **119 optimized passes**, and **all 12 ordered operations pass**. Full tests use existing pinned model/native opt-ins. Remaining skips are physical system audio and unavailable visual admission; precompiled internals are outside TSan coverage. Eight packaged process groups pass, including all eight unchanged saved-policy race checks and the new input/lifetime comparison. The 34-file app/ZIP passes strict signatures, signature-normalized same-build executable payload checks and exact extracted-tree comparison. Installed app bytes match the prior baseline; no installation or unscoped GUI occurred.

Earlier source `0ea6225` has 83 focused passes/one skip and 14 native session/import passes, but is not a qualified replacement. Review found its new shared-lease lock-order defect after the full run passed. Its remaining controller/compiler group was stopped with no native test group active; processes were verified terminal before edits. The dedicated pre-fix test fails three assertions. The activity-before-SQL correction passes 92 focused tests/one skip before the fresh, complete qualification above.

The new core tests cover exact Unicode bytes across chunk boundaries, a sparse oversized file before any read, invalid file types, growth/truncation/edit/replacement, parent replacement, cancellation, one actual lock descriptor through nested admission, borrowed reservation ownership and early settings refusal. GUI/controller tests cover unscheduled workers, cancelled drain callers, failed settings saves, plain switching, invalid destinations and quit. Native session tests gate both pre-reservation and post-settings workers, verify detach/reopen and preserve the original encrypted note.

`scripts/import-input-smoke.py` exercises actual CLI processes in a new private workspace. Its optional immutable baseline uses the same sparse input and authored data. Per-process maximum RSS comes from macOS `time -l`, includes startup and remains an uncontrolled component observation. It checks FIFO behavior without assuming the baseline fails, then observes the collector's settings descriptor and probes its real kernel reservation while stdin remains pending. A separate owned wipe establishes ordering; source IDs and removed-source counts distinguish a late import from retained original data. Every process binary is hash-checked.

```sh
swift test --filter 'LibraryImportFileTests|ImportLifecycleModelTests|ImportPreparationTests|VaultSessionTests'
OSWIND_TEST_NATIVE_VAULT=1 swift test --filter 'VaultSessionTests|NativeVaultImportPreparationTests'
python3 scripts/import-input-smoke.py /absolute/path/to/oswindctl --root /new/private/fixture
```

The process harness deliberately wipes only its newly created authored fixture libraries. It never targets normal history or a selected GUI library. Optional `--baseline /absolute/path/to/older/oswindctl` retains before/after results. No capture, account, provider request, physical power change or installed app update is part of the harness.

The final release comparison uses immutable signed CLIs: source `d3f0181` (`9fce6ac3…`) and source `94f60b0` (`5eb0edd0…`). Every binary is hash-checked before and after its operations.

| Owned case | Prior signed build | Current signed build |
| --- | ---: | ---: |
| 100,000,001-byte sparse file, median process maximum RSS | 118,161,408 bytes | 18,317,312 bytes |
| Pending collector holds kernel reservation | No | Yes |
| Notes removed by concurrent complete wipe | 1 | 2 |
| Pending collector notes surviving completed wipe | 1 | 0 |
| FIFO import | Refused, no writer needed | Refused, no writer needed |

RSS has three samples per build in after/before/before/after/after/before order. It includes startup, uses a sparse zero-filled file just over the JSON limit and is not a general accepted-import/desktop/energy benchmark. Current samples are 18,284,544 / 18,317,312 / 18,350,080 bytes; prior samples 118,161,408 / 118,128,640 / 118,194,176 bytes. Host/cache isolation is not established. The preliminary debug/release observation remains local and separate from these final signed-release measurements.

The old pending-input sequence proves an actual late collector note remains, checked by its returned source ID and authored text; the original marker was erased. In the corrected sequence the complete wipe waits for input/admission and removes both notes. Both CLIs refuse FIFOs in this observation, so no FIFO baseline defect is claimed.

Retained development failures: a test array's optional URL caused the first compile refusal. The next run's six assertions expose the plain-library no-op switch; after the guard fix, the same controller test passes. The pre-fix shared-lease regression also remains, together with the stopped-qualification receipt and a test-only asynchronous assertion compile correction. These logs remain separate from final-source qualification and are not relabeled as passes.

The import proof does not establish a global all-writer wipe guarantee. Non-import preparation paths still need an equivalent audit; for example, CLI `note` currently embeds before its insert without an outer reservation and uses its existing per-command default privacy policy. This remains follow-up work for the broader policy/lifetime admission layer.

Complete daily desktop/power, learned privacy/media quality, sync/distribution, full competitors and the independent intermittent native detach gate remain open. All feature status promotions require evidence at their own scope.
