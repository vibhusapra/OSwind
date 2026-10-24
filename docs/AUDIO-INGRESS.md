# Bounded live audio ingress

Audio has two separate capacity boundaries: raw device ingress and the downstream transcription queue. Bounding only transcription does not bound copied callbacks waiting for the UI actor. Each microphone tap or ScreenCaptureKit stream now owns an independent sink; callbacks copy directly into that sink instead of scheduling one dispatch block or actor task per input buffer.

## Storage and overload

| Boundary | Configured limit |
| --- | --- |
| Input callback | 32,768 normalized mono Float32 samples, at 16 kHz |
| Partial segment per input source | Fewer than 480,000 samples / 30 seconds |
| Completed waiting segments per input source | Three |
| Scheduled actor delivery per input source | One |
| Downstream waiting transcription chunks | Three, shared across both sources |
| Active transcription | One |

These are application-owned sample/queue limits, not an RSS ceiling for CoreMedia, AVAudioEngine, conversion, inference, WAV files or macOS. Callbacks take a short lock while appending and occasionally checking one complete segment with Accelerate RMS. This removes an unbounded delivery backlog; it is not a hard real-time latency guarantee. Legitimate device callbacks exceeding the configured limit stop with a retry reason and require physical compatibility testing.

When the completed ingress mailbox fills, the newly completed segment is dropped. Existing queued segments preserve their source times. Audio settings retains a separate lost-duration warning, including drops at the shared transcription queue; a successful later transcript cannot hide it. Starting another recording clears that run's warning. The count covers capacity drops, not silence, privacy rejection, cancellation, ASR errors or every possible OS/device gap.

Explicit Stop audio synchronously reclaims every completed/partial segment still waiting for the controller actor. The ordinary minimum-duration, silence, privacy and downstream-capacity rules still apply; Stop is not a guarantee that every captured sample will be saved. Pause, lock and privacy stop discard pending input. Sink delivery and synchronous finish cannot interleave on the controller actor.

## Source and format ownership

Each ScreenCaptureKit stream retains its own output/delegate and sink. Late old callbacks can reach only the old inactive sink. No object-address lookup routes a callback into a newer recording. The controller also retains its epoch/session and privacy admission checks.

System audio requires ready, valid, mono, packed native-endian Float32 LPCM at exactly 16 kHz, consistent frame/packet layout, one buffer and byte count matching the declared frames. These checks occur before copying PCM into the sink. Format/buffer failure and `didStopWithError` stop recording and display a retry reason; this is explicit restart behavior, not automatic device recovery.

Microphone conversion is owned by its serialized AVAudioEngine tap. It accepts the originally configured format, bounds converted capacity before allocation, downmixes/resamples to 16 kHz mono and refuses changed formats or conversion errors. Zero-output conversion buffers are allowed. No audio device or microphone permission is needed to exercise the converter with generated PCM.

System-audio application filtering uses the same case-insensitive bundle-ID exclusion helper as foreground privacy. This does not isolate private background tabs or establish atomic privacy across a foreground transition. The source filter is created from the background-inclusive shareable-content inventory at startup. A matching excluded-app launch stops active system-audio work and requires explicit restart with a fresh filter. Notification handling is cooperative; first-sound atomicity, child-process attribution and broader application behavior remain acceptance gates. See the [native two-source fixture](NATIVE-SYSTEM-AUDIO.md).

## Verification and remaining work

The fixtures stall the UI actor while supplying many complete segments, check bounded waiting storage and exact drop accounting, race concurrent callback writers, transfer pending/final segments without duplicate delivery, and reject late callbacks after stop. Real generated CoreMedia buffers exercise the adapter; device-free AVAudioConverter fixtures exercise 44.1/48 kHz stereo downmix/resampling and format/size refusal. Controller fixtures verify failure stops its owned resource, old sinks cannot affect restart, final ingress reaches source admission, and overload warning/reset behavior.

```bash
swift test --filter 'AudioIngressTests|AudioPrivacyTests|AudioLifecycleTests|AudioMemoryTests|LibraryWorkspaceTests'
```

Actual microphone/system-audio capture, device/route interruption and restart, startup filter behavior across newly launched apps, source timestamps under gaps, native warning visibility, callback/UI latency, physical power and broader hardware/macOS compatibility remain open. Queue contracts do not prove an energy improvement or competitive ranking. See [privacy lifecycle](AUDIO-PRIVACY.md) for admission boundaries.

[Final signed evidence](../benchmarks/audio-ingress-v1.json): 728 normal cases (699 pass / 29 opt-in skips), 231 native/model cases, 722 distinct passes / six remaining opt-in cases, 233 TSan passes and eleven final process groups. The attempt ledger retains the initial vault inventory refusal and normal recovery, followed by two fresh passing fixtures; no forced detach or identity relaxation was used. This is not an entirely failure-free qualification history.
