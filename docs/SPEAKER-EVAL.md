# Natural speaker evaluation

The raw timeline API and `oswindctl diarize` expose anonymous recording-local speech intervals before word attribution. Both this API and normal transcript annotation share the same serialized native model runtime. Voice embeddings and speaker profiles are not exported. No detected speech is a valid empty timeline; cancellation, invalid models, decoder failures and deadlines still fail. A missed detection on a speech reference is scored as missed speech rather than excluded. A raw timeline must not be confused with named-person recognition or word-label coverage.

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
curl --fail --location \
  https://api.github.com/repos/joonson/voxconverse/zipball/24bf60be297701cd7e4ef18550c6d390c1b87365 \
  --output /path/to/pinned-annotation.zip
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

This is a small development subset, not a held-out, full-corpus or competitor-app ranking. The measured results below are development ablations with complete-run verification. ASR word error, projected speaker-label coverage, real meeting acceptance and live speaker continuity are separate gates. Broad parity and top-three placement remain unproved.


## Overlap correction and measured results

The previous integration inherited the SDK's exclusive output default. That trims simultaneous voices to one speaker before OSwind's mixed-word safeguard can run. The product now preserves overlapping turns; embedding overlap masking and every clustering parameter remain unchanged. The policy is identified as `overlap-preserving-v1`, and voice-embedding/profile export remains disabled.

[Paired results](../benchmarks/speaker-natural-overlap-v1.json) compare the same model, input hashes, reference hashes and independent scorer in two fixed development subsets. Both repeated runs produce identical error components. No reference speaker counts are supplied to inference.

| Development subset | Pre-fix DER, no collar | Overlap-preserving DER, no collar | Pre-fix DER, 250 ms collar | Overlap-preserving DER, 250 ms collar |
|---|---:|---:|---:|---:|
| Initial five clips | 12.03% | 9.78% | 9.42% | 7.36% |
| Second five, fixed before inference | 8.52% | 7.66% | 6.87% | 5.98% |

This is not a universal per-clip improvement: `ampme` regresses from 4.33% to 5.52% with a 250 ms collar, and `asxwr` changes from 1.42% to 1.44%. Several recordings still undercount speakers, including eight reference speakers detected as four. Full per-clip components and counts remain in the report. Timings are retained, but concurrent activity and uncontrolled caches prevent an isolated speed or energy claim.

The actual product import also processed the 664-second `ahnss` file using GPU-requested Parakeet ASR plus native speaker annotation. All 2,606 timed segments persist and reopen. Of them, 175 intersect model-predicted mixed speech above the product threshold; all 175 remain unattributed. This checks the safeguard against the raw model timeline, not against a human word-level speaker reference. Scoped name search, rename, complete backup/restore and erasure also pass on that real imported source. ASR word error remains unmeasured, and per-operation accelerator placement is not inferred from the compute request.

## Packaged regression verification

The final signed release at source `8cac2b0` reproduces every fixed-policy error component above for both repetitions of all ten clips. Its actual installed CLI also handles three seconds of silence as two empty timelines, refuses existing output without changing it, creates output at mode 0600, fails for a missing model and never creates the forbidden memory library. [Packaged evidence](../benchmarks/speaker-natural-packaged-v1.json) records source/binary/model/input identities, full fixed results, 334 XCTest cases (330 pass/four opt-in skips), 45 focused sanitizer cases (43 pass/two opt-in skips), independent scorer/preparation contracts and process regressions. The app is installed but the normal app/library was not launched.
