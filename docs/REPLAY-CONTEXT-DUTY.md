# Replay context observation duty

Replay's half-second supervisor now observes focused-window metadata instead of repeatedly traversing the complete Accessibility tree while an existing stream is bound. Frame processing still performs fresh complete observations before and after OCR. This reduces redundant tree work; physical energy, sustained desktop capture and competitive performance remain unqualified.

## Observation scopes

The binding scope reads the focused window, title, position and size. It does not inspect focused controls, roles, values, URLs, children or accessible text, and returns no inherited text/URL/security claim. Its result can decide whether a stream needs replacing. It cannot admit a frame.

The full scope retains the existing bounded traversal, secure-field checks, browser context, excluded-app/title/domain rules, identity validation, cancellation and incomplete-tree refusal. It remains mandatory around every frame's OCR. Same-app title/bounds changes discovered by metadata force a fresh full observation and binding replacement. URL and secure-field changes are checked in full frame observations; old metadata never authorizes their retention. No completed AX result is reused for a later frame.

The global coordinator can share an already running full observation with a metadata consumer. A full consumer waits for an already running metadata observation to finish, then requires its own full observation. It cannot join a narrower replacement that raced that completion. The shared worker still permits only one actual IPC operation at a time. Cancellation retains the slot until the underlying operation completes, and one subscriber cannot cancel another subscriber's observation.

The supervisor retains only the bound window metadata. Existing session/permission/idle checks and power-dependent cadence changes continue to retire or replace the stream. Existing complete frame-key checks include PID, bundle, title, URL and bounds. This work adds no claim of atomic pixel/AX context capture, private-browser completeness or calibrated power savings.

## Verification in progress

The focused normal suite passes 75 cases with one explicit visual-model opt-in skip. Tests cover same-app window/title/URL/bounds changes, permission/session/app/cadence changes, secure and excluded contexts, missing browser URLs, late cancellation, and full-versus-binding coordinator races. The first compile failure from an actor-isolated default argument is retained; initialization now happens inside its actor.

The following deterministic fixture drives the production monitor and traversal with 120 simulated half-second scheduler ticks and an authored 301-node tree. It does not sleep for a minute, invoke cross-process AX or use a real screen. Each full traversal performs 1,510 tree-attribute requests; each binding traversal performs four. Frame counts follow the existing normal-power profile intervals. Actual callback drops, restarts and slow native IPC will change real workloads.

| Fixture | Frames | Full observations | Binding observations | Tree-attribute requests |
| --- | ---: | ---: | ---: | ---: |
| Quiet bound stream | 0 | 1 | 120 | 1,990 |
| Light | 12 | 25 | 120 | 38,230 |
| Balanced | 60 | 121 | 120 | 183,190 |
| Detailed | 120 | 241 | 120 | 364,390 |

The full count includes one initial observation and two per authored frame. These counts establish routing/work bounds for the controlled fixture, not throughput, CPU use, physical energy or a comparison with a running older app or competitor.

The current host's read-only permission probe reports Screen Recording and Accessibility access but a locked session. No lock, permission or device setting is changed. A native capture/power trial must use an unlocked, explicitly owned/public window and retain the normal production privacy checks.

## Remaining acceptance

- [ ] Frozen full native/model regression, selected TSan/optimized checks, signed app/package and offline replay/decoder process proofs for this source.
- [ ] Actual focused-window switches within the same app, browser/secure transitions, power changes and cancellation on the signed app.
- [ ] Sustained Light/Balanced/Detailed capture on representative owned/public workloads, with system telemetry, idle controls, storage and process accounting.
- [ ] Physical sleep/lock/unlock, older Macs/macOS, calibrated energy and matched whole-product competitor measurements.

The long-run battery/CPU-budget requirement stays TODO. Broad feature parity and a top-three ranking remain open.
