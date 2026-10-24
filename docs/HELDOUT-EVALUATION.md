# Frozen natural-speech evaluation

The [public protocol](../benchmarks/heldout-protocol-v1.json) records a complete speaker evaluation and a running ASR evaluation. This is not a product ranking. The current product runner is the signed schema-16 release at `184efd6`. Product binaries are unchanged by the benchmark tooling.

Two independent reference scorers measure different things: pyannote.metrics measures anonymous speaker diarization before ASR word attribution; JiWER measures text errors after a complete audio import. Neither metric by itself establishes meeting quality, natural live capture, named-person recognition, word alignment accuracy or parity with another desktop app.

## Speaker protocol

The [232-recording plan](../benchmarks/fixtures/voxconverse-test-v1.json) contains every official test ID and its reference hash. It was fixed locally before any OSwind test inference, using the corrected v0.3 annotations from the [official repository](https://github.com/joonson/voxconverse/blob/24bf60be297701cd7e4ef18550c6d390c1b87365/README.md). These inputs are held out from OSwind tuning; upstream model-training overlap is unaudited.

Two immutable OSwind configurations use the same verified Community-1 model files: the current overlap-aware integration and the preceding exclusive-output baseline. Every recording receives two runs in a fresh process, with the second run reusing that process's backend. No speaker count, annotation or transcript prompt is supplied to the model. Reference labels are parsed only after inference. Hash checks bind inputs, executable, model files and the evaluation harness before and after the entire run.

The primary micro DER includes overlapping speech with no collar; a separately labelled 250 ms collar result is also retained. Both use an explicit evaluation map spanning the complete WAV, including unannotated silence. Components are accumulated across recordings, rather than averaging recording percentages. Empty detections remain missed-speech errors. False-alarm DER can exceed 100%; those cases are not clipped or excluded.

The first test attempt stopped after four scored recordings and five predictions: one official annotation ended at 515.930 seconds while its WAV ended at 515.904. The earlier parser rejected that 26 ms tail. The corrected scorer preserves the annotation and lets the already-declared full-WAV evaluation map crop it, using [pyannote's standard evaluation-map behavior](https://pyannote.github.io/pyannote-metrics/reference.html). Out-of-audio reference intervals are reported. The failed attempt is retained; both complete profiles restart with unchanged model settings and IDs. No recording is removed or model parameter tuned in response to test results.

The [complete test report](../benchmarks/speaker-test-v1.json) covers **232 recordings / 43.54 hours**, both configurations and both repetitions, with final source/model/runner/harness stability verified. Overlap-inclusive micro DER improves from **14.16% to 13.67%** without collars and **11.34% to 10.85%** with 250 ms collars. Both repetitions give identical scores in each configuration. At zero collar, 111 recordings improve, 58 regress and 63 are unchanged. Both configurations undercount speakers in 150 recordings. Every recording, error component and timing is retained. This modest gain does not establish meeting readiness or parity with another app.

```bash
python3 scripts/prepare-speaker-eval.py \
  --annotations /path/to/official-pinned-annotation.zip \
  --plan benchmarks/fixtures/voxconverse-test-v1.json \
  --split test --coverage full-test-set \
  --audio-archive /path/to/official-test-audio.zip \
  --output /path/to/new-private-speaker-assets
python3 -m venv /path/to/scorers
/path/to/scorers/bin/pip install -r benchmarks/requirements-speaker-eval.txt
/path/to/scorers/bin/python scripts/speaker_eval.py \
  --binary /path/to/oswindctl --model /path/to/verified-speaker-model \
  --dataset /path/to/new-private-speaker-assets \
  --output /path/to/new-private-speaker-results --repetitions 2
```

## ASR protocol

The [frozen ASR plans](../benchmarks/fixtures/librispeech-selection-v1.json) select the first five lexicographic utterances for every available speaker in both [LibriSpeech test splits](https://www.openslr.org/12/): 200 clean and 165 challenging utterances, 73 speaker IDs and 49.81 minutes. This is a predetermined selected subset, not a full-LibriSpeech result, a random sample or a meeting benchmark. Audio archive publisher MD5s and locally computed SHA-256s are recorded; selected source/reference and normalized WAV hashes are bound before inference.

The first ASR attempt stopped on a real Whisper import failure after 70 successful imports: upstream timestamps extended beyond a 5.925-second input, and admission refused them. That attempt and its logs are retained. The next complete pass keeps the exact same runner, models, selected IDs and text scorer; the harness now records nonzero imports and continues every planned attempt. Failure accounting was added after this observation and is disclosed rather than calling the pass an untouched initial evaluation.

Three declared profiles run twice per utterance: Parakeet v3 with Neural Engine + CPU, Parakeet v3 with GPU + CPU, and whisper.cpp base.en with its default backend. Each of the planned 2,190 imports starts a fresh process and isolated library. The response must match an actual SQLite record, and raw audio retention stays off. Models are local, explicitly selected and fingerprinted; no inference command downloads models. References never enter inference arguments or prompts.

JiWER aligns case-folded ASCII alphanumeric words with internal apostrophes. Curly apostrophes become ASCII; punctuation is discarded. There is no number expansion or spelling correction and no claim of NIST-equivalent normalization. Empty hypotheses count as deletions; insertions and WER above 100% remain visible. Micro WER uses summed substitution/deletion/insertion and reference-word counts within each split/profile/trial, not mean utterance WER. See the [independent scorer's documentation](https://jitsi.github.io/jiwer/usage/).

```bash
python3 scripts/prepare_asr_eval.py \
  --test-clean /path/to/test-clean.tar.gz \
  --test-other /path/to/test-other.tar.gz \
  --output /path/to/new-private-asr-assets
/path/to/scorers/bin/pip install -r benchmarks/requirements-speech-eval.txt
/path/to/scorers/bin/python scripts/asr_corpus_eval.py \
  --binary /path/to/oswindctl --dataset /path/to/new-private-asr-assets \
  --native-model /path/to/verified-parakeet-model \
  --whisper-binary /path/to/whisper-cli --whisper-model /path/to/ggml-base.en.bin \
  --profiles parakeet-neuralEngine parakeet-gpu whisper-default --trials 2 \
  --output /path/to/new-private-asr-results
```

The preparer needs ffmpeg; it reads selected TAR members rather than extracting archive paths. It refuses selected links, duplicate IDs, changed archives, incomplete selections and invalid converted WAVs. Output is private and must be new. Audio, human reference text and model predictions remain outside Git; the public plans contain IDs and hashes.

## Timing and completion boundaries

Speaker configurations run serially, followed by ASR. A separate pinned synthetic component soak continues; OS/Core ML caches and other background activity are uncontrolled. ASR timing includes normalization, model loading, admission and Apple embedding. Process peak RSS excludes device allocation and child processes. A requested Core ML compute policy does not prove that every operation ran on that processor. These timings do not measure resident throughput, power, battery or competitor apps.

A result is complete only after every declared recording/utterance and repetition finishes and final input/model/runner/harness stability checks pass. Interrupted reports remain retained without final aggregates. A completed ASR evaluation also reports failed imports: nonzero exits or timeouts count as missing delivered text (all reference words deleted) in end-to-end WER, while successful-import WER and failure counts are shown separately. Verification failures such as source drift or an inconsistent saved record still abort the harness. No failed input is dropped or retried within a run. A stalled observation does not authorize restarting an active process. Native desktop/device acceptance and the independent 24-hour capture/power and full-parity gates remain separate.
