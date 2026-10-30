# Owned vault helper phases and missing-member provenance

Implementation is in progress on top of PR #89. This work addresses the cancellation fixture's intermittent phase observation and makes a separate missing-backup-member failure diagnosable. It does not claim to fix the preceding missing member or earlier native detach failures.

## Why this changes

The prior 609-input run retains one failed native attach-cancellation case. Its process-list poll did not observe an active helper; the worker then returned success and the phase was declared unqualified. Four unchanged follow-up cases passed. That evidence did not make the polling observation deterministic.

Preceding hosted source 44e0bb1 also failed `VaultSessionTests.testNativeBusyReaderRemainsClosingUntilRetry` with a generic missing backup member and preserved its attached owned fixture. The diagnostic ZIP contained four completed detach/query reports but no identity for that failed member. Exact cause remains unproven.

## Implementation

An internal `VaultProcess` callback reports the owned child PID after successful launch and cleanup registration, before stdin credential delivery. A distinct input-closed observation runs after stdin delivery; the internal driver hook identifies create versus attach at that phase. Public `LibraryVault` construction installs no observer; the callback receives no arguments, paths, credentials or output.

The owned cancellation fixture registers its cancellation target before allowing the operation to start. A create/attach input-closed callback cancels that exact worker after credential delivery and before transport completion is published. The native fixture also requires its owned helper PID to exist at observation. Native action completion, cleanup, history reopening and independent attachment-absence assertions remain. This removes the process-list sampling race for these two phases. Existing closing/media-drain cases keep their separate observations.

Missing-member errors now retain a safe optional diagnostic: a fixed known-member category, original errno and directory-identity booleans. Unknown names, paths, file contents, inode/device values and credentials are excluded. Localized error messages and missing-file classification remain unchanged. A retained-root replacement test verifies that diagnostics do not redirect reads to the replacement.

The Busy app-session fixture reports fixed operation phases and the safe diagnostic on error. It never prints its passphrase or arbitrary error text. This improves a future recurrence's evidence; it does not identify the historical missing member retroactively.

## Verification and remaining work

- [x] Initial launch-phase native/process run: 13 cases pass, including five attach cancellation/history cycles and create cancellation/resume. The final fixture uses the stronger post-input phase.
- [x] Expanded run: 46 cases pass, including backup trees, safe missing-member metadata and all native app-session cases.
- [x] Final focused run: 47 cases pass, including post-input native create/attach cancellation, stdin ordering, safe metadata, backups and all 13 app-session cases.
- [ ] Normal, TSan, optimized and signed package/process qualification with retained immutable inputs.
- [ ] Published current-source CI and requirement/benchmark receipts.
- [ ] Reproduce or capture the independent missing-member failure's precise provenance and resolve its cause.
- [ ] Resolve older independent detach exit-16 gates, physical desktop acceptance, sustained power/cadence and broad parity.
