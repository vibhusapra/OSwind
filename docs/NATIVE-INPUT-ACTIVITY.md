# Native input activity accounting

Work in progress on top of PR #88. This fixes an inherited automatic snapshot/text/replay admission bug; the sampled-span qualification did not establish natural automatic capture readiness.

## Reproduction and cause

Two owned native automatic-controller pilots saved no source with `Idle · saving energy`, including after a native click. A same-process Core Graphics comparison measured null-event age 1,416,474.46 seconds and any-input age 0.31 seconds. Null-event age is not time since recent keyboard, mouse or tablet activity. [Apple's API documentation](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype%28_%3Aeventtype%3A%29?language=objc) and the installed SDK header require `kCGAnyInputEventType`, represented by the 32-bit all-ones event mask.

The snapshot/text environment and untargeted replay environment both used `.null`. Controlled capture tests supplied their own idle inputs, so their passing observations did not find this native API mismatch. The existing real native-model idle test measures model expiry, a separate behavior.

A shared-reader refactor deliberately retaining the old query reproduces seven failed assertions in five regression cases. The failed native pilots, direct API values, red test log and source digests remain retained.

## Change

Both capture environments use one native activity reader that asks Core Graphics for any-input age in the combined session. Nonfinite or negative native ages defer automatic work. The existing inclusive 120-second activity cutoff, low-power/thermal scheduling and explicit-target replay behavior remain. Lock and permission checks are unchanged. No event tap, input contents, power/lock/idle-policy change or permission request is introduced.

## Verification and remaining work

- [x] Before-fix native counterexample and five-case regression with seven failed assertions retained.
- [x] 267 focused checks: 266 passes and one explicit session/thermal-admission skip, with zero failures; all five new regressions pass.
- [ ] Owned actual native AX automatic-controller observations, overlap queries and pin-before-answer continuation.
- [ ] Full/native-model, selected TSan/optimized and signed package/process qualification on frozen source.
- [ ] Current source CI and published receipts.
- [ ] Representative application transitions, unattended cadence/missed changes and paired physical energy acceptance.
