# Verified interruption recovery for read-only vault queries

[PR #79](https://github.com/vibhusapra/OSwind/pull/79) allows one fresh observation
when a native read-only helper terminates by SIGINT. The interrupted output is
discarded. Normal exit2, other signals, unknown termination, malformed successful
output and thrown native errors do not trigger recovery. A second interruption
remains a failure. Create, attach, detach and unmount retain their existing flow.

`VaultReadOnlyQuery` accepts only attachment inventory, encryption and volume-info
operations. Both attempts share a 60-second budget, including identity validation
and result admission. Before/after checks bind package inode, complete manifest
and image-directory inode. Image contents/mtime can change normally. An absent
image must remain absent; unreadable metadata and symlinks are refused. The
caller must still parse a normal zero exit and prove its actual attachment state.
An interrupted query never counts as an absent observation.

Cancellation is checked before native work and after validation/result delivery.
A cancelled caller cannot start recovery. Closing's existing detached worker can
finish its safe transition despite a parent CLI cancellation request. Native
pipe bounds, cleanup/reaping and the two fresh absent observations after detach
remain. No mutation retry or force detach is added. The shared deadline is an
admission budget, not a hard real-time guarantee: existing Foundation launch,
scheduling and child cleanup can add time.

## Qualification

[Receipt](../benchmarks/vault-query-signal-recovery-v1.json) identifies product
`7e21e0f6fc8d1cbec4c6a49cf284813a6d12b912`, schema 22 and exact signed bytes.
The two-case preceding-policy regression uses an internal query transport seam
and real Python process classification: SIGINT recovery fails, normal-exit-2
refusal passes. Its one reported failure is retained. The immutable preceding
signed CLI is independently compared below.

| Configuration | Defined | Passed | Skipped | Failures |
| --- | ---: | ---: | ---: | ---: |
| Full available model/vault opt-ins | 1,120 | 1,118 | 2 | 0 |
| Selected vault TSan | 132 | 132 | 0 | 0 |
| Selected optimized vault | 132 | 132 | 0 | 0 |

The normal skips remain physical system-audio opt-in and unavailable visual
session admission. Precompiled framework/runtime internals are outside TSan
coverage. Normal PII inference preserves 432 existing short-reference comparisons;
no new representative privacy-quality result follows. Framework warnings remain
in raw logs.

All 12 ordered operations pass: full/TSan/optimized tests, release build, package
proof, doctor, ordinary vault CLI, observed-helper interruption, normal/held-reader
terminal checks, signed native-query fault comparison and final audit. The 34-file
app/ZIP passes strict signatures, same-build normalized raw/signed payload and
complete extracted-tree comparison. Installed/staged bytes remain unchanged;
complete-command owned-process and current-artifact image inventories are empty.
No installation or unscoped GUI launch occurs.

The signed ordinary CLI passes 13 contracts. Parent-terminal Ctrl-C during
create/unlock/lock returns130 and verifies detach/recovery/history. Held-reader
Ctrl-C preserves CLI1, normal hdiutil exit16 and closing state; normal recovery
preserves its note. No forced detach or weakened busy assertion is used.

## Actual native helper fault comparison

The [CLI harness](../scripts/vault-query-interruption-smoke.py) creates a private
synthetic encrypted package and signals only its own status command's inventory
helper. Native process metadata first verifies parent, UID and executable. A
brief SIGSTOP permits full `ps -ww` command and process-birth/stopped-state checks
before the test signal. `kqueue` NOTE_EXITSTATUS independently confirms uncaught
signal2 versus normal exit2; both are calibrated on owned controls. No process
environment or user-terminal data is read.

| Signed CLI case | Trials | Kernel-confirmed outcome | CLI result |
| --- | ---: | --- | --- |
| Preceding source 1de936a, one SIGINT | 4 | Signal 2 | Failure, exit 1 |
| Candidate 7e21e0f, one SIGINT | 4 | Signal 2 | Locked, exit 0 |
| Candidate, two SIGINTs | 3 | Two signal-2 helpers | Failure, exit 1 |
| Candidate, one SIGTERM | 3 | Signal 15 | Failure, exit 1 |

All 14 predeclared trials and 17 targeted helper terminations are retained. The
same matrix also passes against the development binary. No target is missed in
either successful run. The encrypted note survives and native inventory confirms
final detach. These are direct child faults, distinct from parent terminal
Ctrl-C, and do not estimate spontaneous failure probability.

The first observer uses subprocess-based discovery and misses every helper in
its 14 planned trials. Its coverage assertion correctly fails, ordinary cleanup
detaches, and the original receipt remains. The final observer uses bounded native
process metadata plus exact command validation. It never substitutes a missed
signal for a successful fault-recovery result.

Two separate APFS unit fixtures test all three query kinds and repeated refusal.
Their injected SIGINT results come from real Python helpers; subsequent native
hdiutil/diskutil calls, mutations and final observations are real. Those fixtures
do not claim hdiutil was signalled. Each normal/TSan/optimized configuration
retains 29 recovery summaries (three injected signals, two normal mutations) and
two repeated-refusal summaries (no mutations). Ordinary rapid/held-reader traces
retain 154 calls per configuration and the expected single normal exit16.

## Ordinary status cost

A separate [reproducible measurement](../benchmarks/prototypes/vault-query/README.md)
uses the same two signed binaries and one detached synthetic package on an
Apple M5 Max, macOS 26.6.2. Twenty-two alternating AB/BA pairs are fixed in advance;
the first two pairs are warmups. All 44 outputs match, manifest/image identity
stays stable, and its note survives normal reopen.

| Measured calls after warmup | Preceding | Candidate |
| --- | ---: | ---: |
| Median elapsed | 64.12 ms | 66.49 ms |
| p95 elapsed | 70.24 ms | 71.40 ms |
| Median OS-reported waited-child CPU | 19.24 ms | 20.02 ms |

There are 20 measured calls per binary. Median paired candidate-minus-baseline
elapsed difference is **+1.72 ms**; paired differences range from −14.71 to +7.55 ms.
This includes process startup, native IPC and identity checks. Host/caches are
uncontrolled. It is not an isolated guard-cost, causal speed, desktop throughput,
physical power or competitor result. All raw samples are public; no timing retry
or post-hoc outlier removal occurs.

## Remaining scope

This fixes a verified SIGINT-query failure class. The older terminal status2
incident discarded termination reason, so its original exit-versus-signal cause
remains unknown. Passing current terminal checks cannot retrospectively diagnose
it. [Earlier provenance observations](VAULT-TERMINATION.md) remain separately
attributed.

F048 remains partial for real authentication, native GUI/sleep and the OS/device
matrix. Learned production privacy, physical capture/power, sync, notarized
updates, matched competitor workloads and the prior default-library audit remain
open. Broader parity and release acceptance are unproven. Next: native hybrid
privacy quality and production admission/revision/media fences.
