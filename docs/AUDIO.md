# Audio clips, transcripts and imports

Settings → Audio controls microphone and system audio independently. **Start audio** begins local transcription. **Stop audio** finishes the last voiced segment; Pause/privacy/lock stops discard pending capture. Recording is off by default.

Enable **Retain audio clips for playback** to keep future source clips. It starts off. A detected secret suppresses the entire clip because redacting transcript text cannot remove speech from a recording. Sensitive values can span segment boundaries, so detected secrets hide all timed fragments for that clip. Recognized English credential phrases such as “my password is…” conservatively hide the whole transcript as well. Sanitized full text remains available when only a key/value span was masked. Redaction is pattern-based, can over-redact and does not guarantee complete PII removal. The microphone/system labels identify capture tracks, not individual people.

Open an audio memory to play/pause, adjust volume, scrub, or seek to a transcript segment. Clips follow normal retention/storage cleanup and source deletion. Backup/restore preserves clips, structured transcripts and session identifiers. Text JSON interchange strips media paths and sanitizes both transcript representations.

**Import audio file…** processes a chosen local file. WAV and stereo AAC have real conversion tests; other formats depend on AVFoundation decoding and the configured recognizer. OSwind privately snapshots the input before transcription, streams conversion into a separate mono 16 kHz PCM WAV, and optionally retains the original recording's bytes. Editing/deleting the original after snapshot cannot alter that operation's copy. Conversion uses bounded buffers; files longer than 24 hours are refused. The import's time is when it was added, not inferred meeting time; its relative media duration does not create a future recording end time.

```bash
.build/release/oswindctl --data /path/to/library import-audio /path/to/meeting.m4a --retain-audio
.build/release/oswindctl --data /path/to/library import-audio /path/to/meeting.wav
.build/release/oswindctl --data /path/to/library search 'kind:audio checklist'
```

CLI retention is explicit per import with `--retain-audio`. The app import follows the current Audio retention setting. Importing is an explicit file action; foreground capture exclusions do not classify the file's contents. Both paths apply transcript redaction.

Audio settings offer **Whisper.cpp** or **Parakeet v3 · Core ML**. Whisper uses a configured local executable and ggml model. Parakeet uses pinned FluidAudio 0.17.7, an explicitly selected directory of compiled `Preprocessor.mlmodelc`, `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc` and `parakeet_vocab.json` files. Recognition never downloads/resolves model repositories or purges a caller's cache. Run `python3 scripts/setup-native-speech.py` to install the pinned model (483 MB / 22 files) with per-file SHA-256 verification and atomic no-replace publication, then choose the printed directory in Audio settings. Existing installs are verified without downloads; `--verify-only` fails locally if absent. Corrupt existing directories are preserved and refused. Interruptions clean the current private stage; crash/SIGKILL-stage recovery and resumable downloads remain pending. The one-click app download UI remains pending. You can also choose an existing compatible local directory. NVIDIA's [base weights](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) are CC BY 4.0; preserve NVIDIA/FluidInference attribution. The [conversion card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) has inconsistent prose (Apache) versus metadata (CC BY); no weights are redistributed here.

Parakeet exposes Neural Engine + CPU, GPU + CPU and CPU-only Core ML policies. Intel requires CPU-only or Whisper. A policy requests available compute units, not proof of where every operation executes. One model remains resident; capture/import requests serialize. **Release resident speech model** frees it when current work finishes. Changes of model path/compute replace the resident model. Replacing files at the same path requires releasing it first. Startup prepares native models before requesting microphone access; pause/cancellation/source changes invalidate activation. Queued recognition cancels promptly. Core ML compilation/inference can finish after cancellation or its time budget, but such results are discarded before admission; there is no hard process-kill guarantee for native calls. SDK debug transcript logs and console mirroring are disabled.

```bash
.build/release/oswindctl --data /path/to/library import-audio /path/to/jfk.wav \
  --engine parakeet --native-model /path/to/compiled-parakeet-v3 --compute neuralEngine
```

Parakeet returns word timings; Whisper returns recognizer segments. English-only `.en` models are intended for English; choose multilingual weights for other languages. Timestamp resolution follows the recognizer's segments. Session IDs are preserved for grouping, but meeting detection, a meeting-session UI, word highlighting, named speakers, diarization and hotwords remain open work.

Temporary input/recognizer workspaces use private permissions and held leases outside the live library. Normal completion/cancellation removes owned work; subsequent operations conservatively clean recognized abandoned stages. Saved transcripts survive optional additional-index failures. Library switching cancels an in-flight import. Live capture rechecks lock, epoch and current privacy rules after ASR; polling gaps and changing foreground context remain limitations.

Schema 8 prevents older binaries from silently rewriting away structured transcript fields. Schema-6/7 identities and vector keys survive upgrade. A muted runtime test on this Mac verifies the actual player clock, pause, seek, finish and stopping on deletion; it also passes ThreadSanitizer. Native microphone/device-change, button/focus/accessibility and file-panel acceptance remain separate.

![Audio memory with source playback](../assets/audio-detail.png)

![Audio settings](../assets/audio-settings.png)
