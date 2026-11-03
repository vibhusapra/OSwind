# Persistent native targeted capture qualification

This experimental developer harness uses the real CaptureController, ScreenCaptureKit, Vision, Apple sentence vectors and store in one long-lived process. It explicitly targets one generated fixture bundle/PID/window, with no foreground fallback, permission requests or keep-awake changes. Initial source admission must occur within a bounded 15-second startup; all cold-start deferrals remain in coverage counters. Completion checks require a joined close, finite monotonic records, no oversized clock/cadence gaps and at least 90% admitted attempts. `uninterruptedCapture` separately requires zero deferrals.

Tooling source `b3aad61dfd803574cae7d5da65ca8f76fc0771ee` binds 692 committed inputs plus three changed files. All 690 preceding production/test inputs are unchanged; actual production runtime remains `87ddff0`. The release control selection passes two ordinary serialization/startup methods and skips the explicit native method. It is not a full-suite rerun.

The actual persistent native pilot completes 12 requests and 12 sources over 65.35 seconds with zero errors, deferrals or oversized gaps, and normal exit. Separate checks verify exact generated window identity, five OCR regions, retained images/native vectors and source counts, frozen worker/resources, producer join/store close and fixture cleanup. Seven altered-record controls reject. Two source JPEGs were visually inspected and contain only generated content.

- [Reviewed pilot](../benchmarks/native-targeted-capture-pilot-v1.json)
- [Committed inputs](../benchmarks/native-targeted-capture-inputs-v1.json)
- [Raw source/log/receipt/generated-image evidence](../benchmarks/native-targeted-capture-raw-v1.zip)

## Retained failures and scope

The first actual 65-second pilot saves twelve sources, then traps on a duplicate terminal dictionary key. A typed Codable terminal report and ordinary encoding control fix that harness bug. A subsequent cardinality-only test assertion was incorrect and is removed; semantic field/round-trip checks remain. Two following pilots safely discard changing source metadata at the first frame and join/close cleanly. The fixture now waits for three stable own-window ScreenCaptureKit observations, and the harness permits recorded retries within its startup bound. No timer, denominator or failed run was reset or relabeled. An initial freezer falsely matched the word error inside a compiler source excerpt; its failure is retained. Full local crash data stays local; only the exact owned failure symbols are included publicly.

The initial parent folder was named locked-control because the preceding GUI attempt encountered a locked Mac. Actual worker prerequisites then reported an unlocked session and existing capture access, and real capture occurred. Its folder name does not make it a refusal control. The later final GUI check confirms PAUSED on invalid resume and clears the repaired footer to Paused without capture; it neither grants nor qualifies GUI capture access.

## Incomplete long run and remaining acceptance

**Subsequent terminal assessment:** this attempt stopped incomplete after ENOSPC in heartbeat/stop/fixture-exit writes. Its stale running status is not current liveness or completion evidence. Last reported uptime is 27,657.44 seconds, with 1,380 attempts, three saved sources and 1,377 lock deferrals. Exact owned PIDs are absent; original child exit codes were not persisted. See the [failure and controller fix](SOAK-CONTROLLER-RECOVERY.md). The attempt is preserved and is not restarted.

A separately rooted run requests 86,400 seconds at 20-second intervals from the frozen successful-pilot worker. Only startup and first real source are established at publication. Keep its process/root/executable identity, every error and lock/source/sleep gap; never restart it silently. A shorter, suspended or incomplete run is not uninterrupted 24-hour capture. Manual requests deliberately bypass automatic duplicate suppression and idle/backoff; Light selects image dimensions/encoding only. Process RSS/CPU is distinct from app-attributed watts, calibrated wall power or battery life. Other development load remains uncontrolled.

Visual inspection found blank right/bottom padding around the native window inside the JPEG. Reproduce and fix native scaling, then test crop bounds against generated pixel/color oracles on actual hardware. The frozen baseline uses a whole generated window and does not establish selected-crop correctness. [Apple scaling configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/scalestofit) and [point-to-pixel scale](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale) guide the investigation; no crop leak is claimed from the padding observation alone.

Automatic native GUI cadence, sleep/lock/resume, broader app/AX/audio/model quality, controlled energy comparisons, durable joining responses/full device sync, physical two-Mac/provider, production signing/notarization/Keychain and whole-product parity/ranking remain open. All 83 feature statuses remain unchanged.

The controller accepts an explicitly frozen XCTest bundle/provenance, separately compiled fixture and owned output parent. Its published raw preparation recipe is source-specific. Keep mutable `.build` outputs separate from active workers. Run the opt-in worker only with existing appropriate access and generated content.
