# Bounded normal recovery after a busy detach

An encrypted-library lock can encounter a reader that releases its file shortly after `hdiutil detach` fails. OSwind now permits up to two additional normal detach attempts after a normal exit 16, provided fresh observations still identify the original mounted image. A reader that remains open still blocks locking. No force flag is used.

The first retry waits 150 ms and the second waits 400 ms. After each wait, OSwind checks cancellation, validates the pinned package, manifest and image, and obtains a fresh same-image mounted proof before acting. Changed or unknown observations, an unmounted image, other exit statuses, signals and unknown termination cannot authorize another mutation. The existing moved-package normal-unmount fallback remains separate and gains no additional retry.

Every native action retains its 30-second helper timeout. Thus a busy request can spend up to 60 additional seconds in two native detach calls, plus pauses and inventory checks. The pause budget is not a wall-clock completion guarantee. Successful exit status, a failed exit followed by absence, or one absent inventory reply still cannot report locked: the existing verifier requires two further fresh absent observations. Exhaustion preserves an error/closing state; check vault status before assuming it is locked.

## Why this changed

[Hosted run 41291021469](https://github.com/vibhusapra/OSwind/actions/runs/41291021469) passes the instrumented moved-package test and all 13 app-session cases, but the separate rapid-lock fixture fails at its final lock. Its uploaded trace records a normal detach exit 16 with Resource busy and a later normal cleanup detach exit 0. The observed self descriptor at the failure boundary is the package-host operation lock, outside the mounted volume. That does not identify the busy owner or establish the operating-system cause.

This change addresses the observed recovery opportunity. It does not explain the earlier missing-session failure in [run 41288968230](https://github.com/vibhusapra/OSwind/actions/runs/41288968230), and neither failed run is reclassified as passing.

## Validation

The transition contracts cover bounded retries, disabled/invalid budgets, changed image/package identity, disappearance during backoff, unknown inventory, cancellation, non-busy failures, signal/unknown termination and independent absence confirmation. Existing moved-package fallback cases remain covered.

Two native controls use owned encrypted APFS fixtures. A reader held open must cause all three normal detach attempts to fail, preserve closing state and retain history for a later explicit recovery. A reader released only after the first observed normal busy exit must permit the original lock request to recover, with the known reader descriptor absent before the successful action. Rapid lock/unlock separately verifies history and attachment inventory.

```bash
swift test --filter VaultEjectTransitionTests
OSWIND_TEST_NATIVE_VAULT=1 swift test --filter NativeVaultDetachSettlementTests
```

The [774-input, Git-bound receipt](../benchmarks/vault-busy-recovery-v1.json) qualifies source `0538b9d` through all 12 stages. The full suite has 1,829 passes and 88 opt-in skips across 1,917 cases. Focused sanitizer and optimized builds each have 46 passes and 14 opt-in skips, including all 29 mandatory transition cases, with no race warnings. All 38 actual owned native cases pass without skips, adding 36 distinct passes to the general run: 1,865 distinct methods pass across those two runs. The remaining 52 opt-in methods are enumerated in the receipt; earlier model/hardware receipts remain separate.

The released-reader trace records `[16, 0]`; the held-reader control records `[16, 16, 16]` before explicit later recovery. Signed CLI vault, held-reader controlling-terminal interruption and inventory-query interruption checks pass. Strict signatures and exact 34-file archive/extraction equality pass; all 22 protected prior application trees remain unchanged. The original four-case/eight-assertion contract failure and actual released-reader native failure remain retained. Native UI, supported-device coverage, physical power, notarization and whole-product parity remain separate acceptance work. [Hosted run 41297577807](https://github.com/vibhusapra/OSwind/actions/runs/41297577807) at publication `9cacf46` passes both native and benchmark jobs. Earlier failed runs remain failed and their causes remain unproven.
