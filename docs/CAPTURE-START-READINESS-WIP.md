# Capture start readiness

The [later native pilot receipt](../benchmarks/native-targeted-capture-pilot-v1.json) includes the actual final repaired-footer check after the session became available: invalid resume stays PAUSED, valid repair clears the footer to Paused, zero sources, and the QA app exits. The original locked preflight and earlier publication remain unchanged. Positive collection on that GUI identity remains unqualified.

A native release QA check found that invalid capture settings could leave the header claiming CAPTURING while the footer correctly refused collection. Startup now validates scope before permission checks and before setting running. Changes that make an active scope invalid cancel pending work and pause it. Repair updates only the matching scope-error status and leaves capture paused until explicitly resumed.

Runtime `87ddff021500d0849245d9894ccb95473c13a81e` binds 690 committed inputs. The affected 99-method selection has 98 passes, one explicit native-vault skip and zero failures in Debug, Thread Sanitizer and optimized builds. All six new methods pass each mode. The baseline retains five failed methods/13 assertions and one passing permission control. Five altered-log controls reject. The checker also verifies exact identities, commands, source pins and retained prior observations. An initial checker referenced the preceding runner filename; its failure is retained and the corrected checker passes without rerunning product tests.

The first fresh native candidate shows PAUSED/Resume capture for an invalid resume and saves no sources. Repairing its area exposed a stale footer. The final source fixes that footer and passes software assertions; the final GUI launch was blocked by the Mac locking. CLI doctor confirmed the lock, and no permission or unlock changes were attempted. The isolated final candidate has a saved owned-library fallback before first launch. The first and final product/QA packages remain separate and frozen.

- [Reviewed receipt](../benchmarks/capture-start-readiness-v1.json)
- [Committed inputs](../benchmarks/capture-start-readiness-inputs-v1.json)
- [Raw source/log/receipt evidence](../benchmarks/capture-start-readiness-raw-v1.zip)

## Remaining work

- The later native repaired-footer/paused check passes. Deliberate positive GUI resume and producer lifecycle still need an appropriately authorized app identity.
- Run the prepared persistent targeted-native worker pilot, then a separately identified sustained run. Manual requests bypass automatic duplicate suppression and idle/backoff; this baseline cannot establish automatic foreground scheduling or uninterrupted desktop coverage.
- Record admitted sources, lock/source deferrals and wall/uptime/tail gaps. A configured or running worker is not a completed 24-hour pass.
- Measure settled, controlled paired workloads before interpreting optional whole-system IOReport/SMC estimates. CPU/RSS and sensor estimates are distinct from app-attributed watts, battery or wall-plug measurements.
- Complete durable joining responses and actual sync producer/session integration, physical two-Mac/provider acceptance and production signing/notarization/Keychain qualification.

All 83 feature records and the competitor landscape remain unchanged. Full parity, top-three ranking and completed v0 acceptance are not established.
