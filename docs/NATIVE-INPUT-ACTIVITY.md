# Native input activity accounting

Implemented on top of PR #88 as source 07f5de5 / [PR #89](https://github.com/vibhusapra/OSwind/pull/89). This fixes an inherited automatic snapshot/text/replay admission bug; the sampled-span qualification did not establish natural automatic capture readiness.

## Reproduction and cause

Two owned native automatic-controller pilots saved no source with `Idle · saving energy`, including after a native click. A same-process Core Graphics comparison measured null-event age 1,416,474.46 seconds and any-input age 0.31 seconds. Null-event age is not time since recent keyboard, mouse or tablet activity. [Apple's API documentation](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype%28_%3Aeventtype%3A%29?language=objc) and the installed SDK header require `kCGAnyInputEventType`, represented by the 32-bit all-ones event mask.

The snapshot/text environment and untargeted replay environment both used `.null`. Controlled capture tests supplied their own idle inputs, so their passing observations did not find this native API mismatch. The existing real native-model idle test measures model expiry, a separate behavior.

A shared-reader refactor deliberately retaining the old query reproduces seven failed assertions in five regression cases. The failed native pilots, direct API values, red test log and source digests remain retained.

## Change

Both capture environments use one native activity reader that asks Core Graphics for any-input age in the combined session. Nonfinite or negative native ages defer automatic work. The existing inclusive 120-second activity cutoff, low-power/thermal scheduling and explicit-target replay behavior remain. Lock and permission checks are unchanged. No event tap, input contents, power/lock/idle-policy change or permission request is introduced.

## Verification and remaining work

- [x] Before-fix native counterexample and five-case regression with seven failed assertions retained.
- [x] 267 focused checks: 266 passes and one encrypted-fixture opt-in skip, with zero failures; all five new regressions pass.
- [x] Owned actual native AX startup plus three explicit automatic calls at real two-second gaps: two sources with two samples each, two joins, overlap/source-start controls, immutable pinned evidence and retained chat/recap. Independent read-only output check verifies zero media, two sessions/ranges and one pinned source. Only context routing is bound to the owned fixture; no text, clock or idle input is injected. This is not unattended cadence or representative application acceptance.
- [x] 609 frozen inputs: selected TSan and optimized runs each pass 266 / one explicit skip; all five new idle and 35 span cases pass in each build. All 18 non-full-suite signed process/archive/package stages pass.
- [ ] Broad-run acceptance: the full suite retains 1,291 passes, two skips and one failed native-cancellation case (two assertions, one unexpected). The fixture did not observe its active attach phase. Four unchanged native-cancellation follow-up cases pass, but the original 18/19-stage result remains partial; phase observation is not yet deterministic.
- [x] Both exact-source CI jobs pass in run 40953442896; [full partial-run receipt](../benchmarks/native-input-activity-v1.json) preserves the failed native phase and independent preceding CI failure.
- [ ] Representative application transitions, unattended cadence/missed changes and paired physical energy acceptance.

The first post-fix native pilot captured its initial source, then correctly refused the harness's explicit target argument on a non-manual call. The corrected probe pins only its context routing to the owned fixture and uses normal automatic calls. This harness correction is retained separately from the null-event defect; production target-admission behavior is unchanged.

The preceding source 44e0bb1 hosted native-vault subset fails with a missing backup member in the Busy app-session case and an attached-fixture cleanup failure. The downloaded diagnostic artifact is digest-verified but lacks that case's missing-member identity. Cause remains unproven. This input fix does not change vault/file-tree lifecycle code.

The new native reader itself has five passing cases in the full, TSan and optimized builds. The failed broad-run method is `NativeVaultCancellationTests.testCancelledOwnedUnlockCanImmediatelyRecoverWithHistory`: its polling observer did not find an active attach helper, after which the worker returned success and the phase was declared unqualified. No timing or product cause is inferred without that missing observation. The unchanged four-case follow-up qualifies its observed phases and verifies zero matching images afterward. These passing observations do not rewrite the original run or resolve intermittent phase observation. Both current hosted CI jobs pass; the preceding missing-member CI failure remains an independent unresolved gate.
