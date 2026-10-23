# Natural speaker evaluation

The raw timeline API and `oswindctl diarize` expose anonymous recording-local speech intervals before word attribution. Both this API and normal transcript annotation share the same serialized native model runtime. Voice embeddings and speaker profiles are not exported. A raw timeline must not be confused with named-person recognition or word-label coverage.

## Reproduce

Use macOS 15 or later and a verified local Community-1 model from OSwind's model setup. No inference command downloads models or opens the normal memory library.

```bash
swift build -c release --product oswindctl
.build/release/oswindctl diarize /path/to/audio.wav \
  --speaker-model /path/to/local/speaker-model \
  --repetitions 2 --output /path/to/new-timeline.json
```

The input is privately snapshotted and normalized using the product's audio path. Output creation refuses an existing file and starts with mode 0600. The first run includes resident model loading; later repetitions reuse the same process backend. OS/Core ML compilation caches remain uncontrolled. The API accepts the actual normalized duration independently of ASR words, validates intervals and clips at the source boundary using the existing 0.5-second rounding tolerance.

The [predetermined five-clip plan](../benchmarks/fixtures/voxconverse-dev-v1.json) selects the first five lexicographic VoxConverse development identifiers before inference. Their reference speaker counts are not passed to the model. Annotations are pinned to an immutable official repository commit. The [official dataset README](https://github.com/joonson/voxconverse/blob/24bf60be297701cd7e4ef18550c6d390c1b87365/README.md) provides download links, corrected v0.3 labels, attribution and CC BY 4.0 terms; original video copyright remains with its owners. Source audio is kept outside Git.

```bash
python3 scripts/prepare-speaker-eval.py \
  --annotations /path/to/pinned-annotation.zip \
  --plan benchmarks/fixtures/voxconverse-dev-v1.json \
  --output /path/to/new-private-subset
python3.14 -m venv /path/to/eval-environment
/path/to/eval-environment/bin/pip install -r benchmarks/requirements-speaker-eval.txt
/path/to/eval-environment/bin/python scripts/test-speaker-eval.py
/path/to/eval-environment/bin/python scripts/speaker_eval.py \
  --binary .build/release/oswindctl --model /path/to/local/speaker-model \
  --dataset /path/to/prepared-subset --output /path/to/new-evaluation
```

Preparation can read a complete local audio ZIP with `--audio-archive`. Otherwise it retrieves only selected ZIP members using exact HTTP ranges. Every response must preserve the strong ETag, final URL, total size and requested byte range; ZIP CRC and reference hashes must validate. Existing output directories are preserved, and failures leave an explicit failed manifest.

## Scope and gates

The independent scorer is pinned `pyannote.metrics` 4.2.0. It computes permutation-invariant diarization error with 0 and 0.25-second collars, includes overlap, and scores the entire source WAV duration, including unannotated silence. Aggregate DER weights reference speaker time; it is not the arithmetic mean of clip percentages. Known-answer tests cover permutation, undersegmentation, overlap, collars, aggregation and malformed references/timelines. These conventions follow the [metric reference](https://pyannote.github.io/pyannote-metrics/reference.html).

Report inference real-time factor separately from preparation and whole-process time. macOS peak process RSS excludes GPU/ANE allocations, background services and system power. Each clip starts a fresh process; repetitions within it reuse the model. A source/model/binary hash drift, failed clip, output error or unexpected library write prevents a completed evaluation. Concurrent local component-soak work and data downloads may affect timings.

This is a small development subset, not a held-out, full-corpus or competitor-app ranking. Natural scores are pending until the complete run is verified. ASR word error, projected speaker-label coverage, real meeting acceptance and live speaker continuity are separate gates. Broad parity and top-three placement remain unproved.
