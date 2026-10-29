# Native vault termination provenance

[PR #78](https://github.com/vibhusapra/OSwind/pull/78) preserves whether a native
helper exited normally, died from a signal, or returned an unknown termination
class. Numeric status alone cannot distinguish the owned normal-exit-2 and
SIGINT controls. Foundation provides a separate
[termination reason](https://developer.apple.com/documentation/foundation/process/terminationreason-swift.enum).

The safe summary adds `termination`; public errors say `hdiutil exit 2` or
`hdiutil signal 2` as appropriate. Neither error text nor error reflection emits
native output, arguments, credentials or image metadata. Create/attach credential
calls retain their separate unobserved path. Successful native query/action
bodies require a normal zero exit; synthetic zero-status signal/unknown bodies
are refused. Existing cancellation, bounded pipes, native deadlines and reaping
remain. No retry, force detach or relaxed attachment identity proof is added.

## Qualification

[Machine-readable receipt](../benchmarks/vault-termination-provenance-v1.json)
identifies product source `1de936afe68efd75450292e1566dfa89222f4878`, schema22 and
the separately signed CLI hash. The preceding label-only helper regression fails
one case/two reported assertions. The final real helper case also checks the new
termination enum for SIGINT and SIGTERM. The focused selection passes54 cases,
with two native opt-in skips before the complete run.

| Configuration | Defined | Passed | Skipped | Failures |
| --- | ---: | ---: | ---: | ---: |
| Full available model/vault opt-ins | 1,095 | 1,093 | 2 | 0 |
| Selected vault TSan | 107 | 107 | 0 | 0 |
| Selected optimized vault | 107 | 107 | 0 | 0 |

The two normal skips remain physical system-audio opt-in and unavailable visual
session admission. TSan excludes precompiled runtime/framework internals. Normal
PII inference preserves432 existing short-reference comparisons; this is not a
new privacy-quality evaluation. Framework warnings remain in the raw log.

All11 ordered operations pass: full/TSan/optimized tests, release build, package
proof, doctor, ordinary vault CLI, observed-helper interruptions, normal terminal
interruptions, held-reader terminal refusal/recovery and final audit. The signed
CLI passes13 ordinary checks and two observed-helper SIGINT trials. Actual PTY
Ctrl-C during create/unlock/lock returns130, leaves no attachment and preserves
history/recovery. A held reader produces CLI1 and normal hdiutil exit16, preserves
the attached closing state, and recovers normally after reader release. Six
unchanged earlier development repetitions also pass; they do not estimate a
failure probability.

The34-file app/ZIP passes strict signatures, same-build normalized raw/signed
payload comparison and complete extracted-tree equality. Installed/staged bytes
are unchanged. Complete `ps -ww` command parsing and current-artifact image checks
find no owned executable or attachment, including after the separate diagnostic.
No installation or unscoped GUI launch occurs. This run adds no new visual,
physical capture, authentication, energy or competitor acceptance.

The three native fixture configurations export into one shared directory. Their
six complete JSON files are assigned by the logged fixture-suite time bounds;
each configuration has104 normal-cycle calls and50 held-reader calls, with the
expected single normal exit16. The combined stdout/stderr log can interleave
XCTest text inside printed JSON. On-disk exports, not reconstructed log fragments,
are authoritative. An initial unpublished aggregator incorrectly assumed separate
export directories; that draft remains in local artifacts and is superseded by
the explicit association in the public receipt.

## Remaining interruption issue

PR #77's signed held-reader Ctrl-C failure reports numeric hdiutil status2 before
reaching busy refusal. That product discarded termination reason, so its actual
exit-versus-signal class cannot be recovered. Normal recovery preserved its note
and detached the image. The current passing trial does not erase that failure.

A separate [read-only Foundation/PTY probe](../benchmarks/prototypes/vault-signal/README.md)
retains two fixed30-case component runs. The first has15 normal hdiutil exits and
two Python SIGINT terminations. The public-driver run observes two hdiutil and
one Python SIGINT termination, all status2. Observed child groups are separate
in every case. This establishes native query interruption in that analogue;
it does not establish historical vault causality or repair OSwind's lifecycle.
No raw inventory stdout is retained.

[Subsequent source7e21e0f](VAULT-QUERY-RECOVERY.md) now qualifies one bounded
recovery specifically for a verified SIGINT-interrupted read-only query, with a
shared budget and cancellation/identity fences. Repeated interruption, normal
exit2, other signals, malformed output and failed mutations remain refusals.
This earlier source1de936a receipt remains unchanged. Learned production privacy,
physical desktop/power, sync, notarized distribution, matched competitor
workloads, prior default-library audit, broad parity and release acceptance remain
open.
