# Isolated native diarization probe

A component evaluator, separate from the app. It uses pinned FluidAudio 0.17.7 (Apache-2.0 code) and its Community-1 offline diarization assets (scoped CC BY 4.0; preserve upstream attribution/provenance). Model downloads go into the supplied cache directory. It exports segment labels/times, not speaker embeddings.

```bash
swift build --package-path tools/SpeechProbe -c release --disable-keychain --disable-netrc
tools/SpeechProbe/.build/release/SpeechProbe AUDIO.wav CACHE_DIRECTORY REPORT.json
```

The per-command credential flags allow public dependency downloads while the Mac's Keychain is locked; they do not alter credentials. The model load uses `OfflineDiarizerModels.load` with a custom directory, then initializes the manager. This avoids the manager convenience method's blanket cache purge on a first load failure. Source models still follow the SDK's cache policy.

Requires Swift 6.2+ and macOS 15+. The SDK documents a macOS-14 BNNS crash risk for offline diarization; this probe does not test that path. Compute units are `.all`; per-operation device placement/energy is unmeasured. A synthetic two-stock-voice test is a consistency check, not natural-meeting DER or product integration.

To generate the synthetic A/B/A/B source fixture, supply an installed local Kokoro helper (stock `af_heart` and `am_echo`, mono 24 kHz PCM16). Our run used `mlx-audio 0.6.0` and `mlx-community/Kokoro-82M-bf16`:

```bash
python3 tools/SpeechProbe/make-fixture.py --tts /path/to/kokoro-narrate --output /path/to/new-fixture
```

Retain its scripts, individual WAVs, timing receipts, assembled WAV and `reference.json`. Utterance bounds contain pauses, so do not report them as annotated speech-activity/DER ground truth. Compare dominant cluster association over the known A/B/A/B utterances. The published run's raw predictions, reference and limitations are in `benchmarks/speech-diarization-synthetic-v1.json`. Output waveforms/timing can vary with TTS versions; the voice-source association is the synthetic regression.
