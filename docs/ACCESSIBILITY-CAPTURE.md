# Bounded accessibility for capture and audio

Snapshot, replay and live audio perform cross-process accessibility reads in a utility worker. The main actor selects the foreground or explicitly targeted application using `NSWorkspace`, then checks its PID/bundle after the worker returns. It does not traverse the application's accessibility tree. Snapshot reserves its busy flag and generation before the first suspension, so pause, capture-setting changes, task cancellation and another manual request cannot turn a delayed initial context into a new capture.

## Traversal and cancellation

The worker has one active IPC slot. A coordinator shares only currently running observations of the same PID/bundle across capture, replay and audio, with at most eight observers per read. A different/cancelled preceding observation must actually finish before another traversal starts. Completed results are not cached. Each consumer releases its own lease; cancelling a replay or audio session does not cancel a still-observed screen/audio read. The producer is cancelled only after its final observer leaves. Budgets remain cooperative, with no hard process-kill guarantee.

Each native AX object gets its own message timeout before a read. The requested timeout is at most 40 ms, bounded by the remaining traversal budget. OSwind does not change the process-wide timeout. Apple's [timeout documentation](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout) and the installed SDK specify that setting an application object alone does not configure other equal objects; therefore each root, window and descendant is configured individually.

Default cooperative limits are 350 ms, 1,000 distinct window-tree nodes and 8,192 attribute messages. Child arrays are counted before copying and refused above the node budget. A set avoids duplicate/cyclic traversal and bounds the queue. Text is limited to 16,000 characters including separators, with at most 4,000 per value. Reaching that text limit **does not stop security/URL traversal**: a later secure field or address still matters. The focused element is also checked for a secure subrole before text traversal.

A timeout, unreadable node, missing focused window, cancellation or incomplete tree produces no trusted-AX context. It cannot silently admit the partial text/window result. Large or slow application trees can therefore reduce capture availability; their real-world rate and an appropriate default budget need unlocked measurements. The limits are cooperative, **not a hard wall-clock deadline for an OS call**. An executing AX call is not forcibly terminated. Cancellation suppresses its result and retains the slot until the owned worker actually returns.

## Permission and admission boundaries

Accessibility remains optional for native applications. Without that permission, the reader returns only application identity; accessible text and secure-field detection are unavailable. Existing recognized-browser URL requirements still defer browser capture, and ScreenCaptureKit must still select an unambiguous eligible source. With permission on, an incomplete traversal defers capture. This preserves the explicit permission model rather than silently requiring a new grant.

Snapshots repeat the bounded reads around discovery, image receipt and recognition. The final complete read precedes the private JPEG write. A cheap identity/session/permission/generation check and SQLite admission then run without actor suspension; no AX IPC is performed between file creation and source insertion. Failure removes the unadmitted file. Accessibility and pixels remain separate observations, not an atomic screenshot of a URL or protection against all sensitive overlays. See [snapshot privacy](CAPTURE-PRIVACY.md).

Audio now uses the same bounded utility reader throughout startup, timer checks, PCM processing, final flush and admission. Independent consumers can share only a currently running same-application observation; consumer cancellation does not cancel other observers. No synchronous AX traversal remains. See [audio lifecycle, shared-read ownership and limits](AUDIO-PRIVACY.md).

## Verification

`AccessibilityReaderTests` uses owned trees and controlled workers to exercise complete extraction, missing windows, focused/later secure fields, text limits, cycles, wide trees, message/node/deadline budgets, cancellation, main-actor responsiveness, slot ownership and in-flight replay observation sharing. `SnapshotAdmissionTests` drives actual JPEG/SQLite admission and checks pause, settings, lock and cancellation during initial context reading, duplicate manual requests and final identity failure after a JPEG was written.

These fixtures perform no desktop reads, permission prompts or input. Their deterministic worker checks do not measure native AX IPC latency, real browser compatibility, capture availability, energy or competitor performance. [Aggregate evidence](../benchmarks/accessibility-capture-v1.json) records 624 distinct passing cases, six remaining opt-in cases and 111 TSan passes, plus owned encrypted-volume, actual Vision/model, signed process and package checks. See the [progress ledger](PROGRESS.md) for the full completion boundary. Unlocked native interaction and physical browser/power measurements remain release gates.

```bash
swift test --filter 'AccessibilityReaderTests|SnapshotAdmissionTests|Replay|AudioLifecycleTests|AudioPlaybackTests'
OSWIND_TEST_NATIVE_VAULT=1 swift test --filter 'AccessibilityReaderTests|SnapshotAdmissionTests|NativeVaultVisualIndexTests'
swift test --sanitize=thread --filter 'AccessibilityReaderTests|SnapshotAdmissionTests|AudioLifecycleTests|AudioPlaybackTests'
```
