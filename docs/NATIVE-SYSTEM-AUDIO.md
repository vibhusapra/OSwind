# Native system-audio fixture

This opt-in probe exercises real ScreenCaptureKit audio through OSwind's production application inventory, PCM decoder and bounded sink. Two owned applications play different generated tones at the same time; a requested include-only filter selects one application per stream. The probe checks native format/readiness, callback/sample counts, decoded amplitude and suppression of the other known tone. Raw captured samples remain in memory. Generated source WAV files and aggregate observations are retained privately.

This establishes a controlled native buffer/source check. It does not establish complete AudioController startup/permission/ASR/foreground privacy behavior, arbitrary application/child-process ownership, microphone input, device/route recovery, source timestamps under gaps, battery use or a competitor ranking.

## Run

Use an unlocked Mac with already granted capture access. The harness never requests permission, changes system volume, opens a user library or grants new access. It plays soft generated tones for about three seconds per selected source. Source apps launch through LaunchServices and remain silent until their explicit playback marker appears. Each source's actual PID and bundle identity come from a private atomic readiness file. Cleanup stops playback and terminates only the verified owned executable.

```bash
python3 scripts/native-system-audio-smoke.py \
  --root .artifacts/owned-audio-NEW-RUN \
  --cli /absolute/path/to/OSwind.app/Contents/MacOS/oswindctl

# Run the same real input path with instrumented production/test code.
python3 scripts/native-system-audio-smoke.py \
  --root .artifacts/owned-audio-tsan-NEW-RUN \
  --cli /absolute/path/to/OSwind.app/Contents/MacOS/oswindctl \
  --sanitize-thread
```

Every root must be new. The CLI is used only for preflight in an explicit isolated library; `swift test` builds the current production inventory/decoder with its opt-in native fixture. A successful CLI doctor does not prove the staged GUI has capture permission. The native test checks its own existing preflight and session state before capture and never prompts. A skipped test does not satisfy the harness: both observation rows must exist and pass.

## Production changes

System-audio inventory includes background/offscreen applications. Their exclusion identities must be considered even if they have no visible window on the current Space. The fixture hides both owned windows and requests production inventory; the separate onscreen-only inventory is recorded for comparison.

A live workspace launch publisher stops system-audio work when a newly launched bundle matches the case-insensitive app exclusion rule. Stop invalidates the epoch, cancels ASR and discards pending input; restarting creates a fresh source filter. Idle controllers and microphone-only authorization keep their existing behavior. Synthetic publisher/controller fixtures cover this path without launching a sensitive app or requesting microphone access.

The notification and stop are cooperative. This does not create an atomic boundary before the first sound from a newly launched application. App lifecycle/child processes that do not emit the expected workspace launch event, attribution shared with other processes, private browser tabs and background URL changes remain separate limitations. No automatic resume or device-route recovery is claimed.

## Retained fixture corrections

Initial direct-shell sources were absent from the onscreen-only inventory. Broader discovery found them, but when both direct-shell sources played, requested single-source streams contained both tones with almost equal amplitude. These observations are retained; their failure is not a passing privacy result. Launching separately through LaunchServices changed the outcome: each selected tone passed and strongly suppressed the other known tone. Process responsibility/attribution is a possible explanation, not a measured diagnosis. The final probe binds PID/bundle identities and records its launch method.

The final hidden-window fixture checks the same production format bounds introduced by [audio ingress](AUDIO-INGRESS.md): actual 16 kHz mono Float32 callbacks are accepted without changing the validator. No general exclusion of every other user application is inferred from suppression of one known tone. Source waveform projection is a fixture-specific scorer, not speech quality or a general audio-leakage benchmark.

Apple describes [application-level audio filtering](https://developer.apple.com/videos/play/wwdc2022/10155/) and [capture configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio). Those API contracts guide the implementation; the native observations remain separate evidence of behavior on the tested Mac.

## Qualified observations

[Runtime07cb8de evidence](../benchmarks/native-system-audio-v1.json) records two normal and two Thread Sanitizer source selections. Each has 48,640 samples in 152 callbacks, 320 samples maximum per callback, 16 kHz mono Float32/flags41, no format rejection/interruption and other-known-tone amplitude suppression ratios from 332,519 to 2,269,098. Both hidden sources are absent from the onscreen-only inventory and present in the production inventory. The separate signed package and eleven process groups also qualify; the physical probe itself uses SwiftPM normal/instrumented code. These short synthetic-tone results do not establish general audio privacy, release-GUI/controller capture, ASR quality or power.
