# Local visual models and qualification

OSwind can convert and run a pinned Google SigLIP2 image/text pair locally through Core ML. The encoder and qualification CLI also support [persisted screenshot/replay visual search](VISUAL-SEARCH.md). That integration adds no image understanding to text-only Ask. Existing text search works without this optional model.

The [source catalog](../models/siglip2-source.json) fixes the original repository revision, eight file sizes and SHA-256 hashes. Google's [pinned model card](https://huggingface.co/google/siglip2-base-patch16-224/blob/75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2/README.md) declares Apache-2.0. Weights are downloaded separately and are absent from this repository and the app bundle. Native tokenization uses pinned Hugging Face Swift code; [third-party notices](../ThirdParty/NOTICES.txt) and transitive licenses are packaged with the app.

## Prepare once

On Apple Silicon macOS, open Settings → Models → Visual memory and choose **Prepare visual model on this Mac**. OSwind downloads the pinned public tools and source files, converts both encoders locally, checks CPU/GPU numerical agreement, then atomically installs the qualified bundle. Selecting it preserves the visual-memory enable switch; enable visual memory and build the index when ready. Preparation uses no recorded history or provider credential.

The packaged CLI offers the same path:

```bash
/Applications/OSwind.app/Contents/MacOS/oswindctl vision prepare
# Explicitly select and enable the prepared model for the chosen library:
/Applications/OSwind.app/Contents/MacOS/oswindctl --data /absolute/library \
  vision prepare --use-model
```

Without `--use-model`, preparation does not open or create a history library or change its settings. `--cache-root /absolute/cache` overrides the preparation cache; `--assets-root /absolute/resources` is a developer override for the bundled, checksum-verified preparation assets. Keep caches outside libraries, backups, vaults and model bundles. Normal users need neither override.

Allow **10 GB free disk space**. The final model payload is **968,536,703 bytes**; the cache also holds approximately 1.54 GB of original public weights/configs, Python and conversion packages. The measured warm-cache preparation used approximately **8.6 GB peak RSS**, substantially more than native search. Lower-memory Macs can select an already prepared bundle from another compatible Mac. Downloads and first-time tool installation can take several minutes. A measured 26-second conversion with cached tools/source is not a first-download or cold-start promise.

Preparation pins [uv 0.13.5](https://github.com/astral-sh/uv/releases/tag/0.13.5), managed Python 3.12.15 and a [48-package frozen script lock](../scripts/convert-visual-model.py.lock). The [runtime catalog](../models/visual-preparation-runtime.json) and generated Swift catalog bind the official uv archive, extracted executable and five bundled assets to their sizes/SHA-256 hashes. Python and packages are installed into the private preparation cache; no shell profile or global tool installation is needed. Conversion runs with an explicit environment, empty credential directory, disabled keyring, `/dev/null` netrc, offline Hugging Face settings and no ambient provider keys. Public downloads use HTTPS. The native search runtime uses Swift/Core ML and needs no Python or server.

Cancel waits for the owned process group to stop. A bundled native guardian also watches for abrupt parent death, retains cache/workspace reservations and stops descendants after the owner is killed. A later attempt cleans abandoned owned workspaces and reuses verified public files. Unfinished owned downloads restart on retry; **byte-range resume is not implemented**. The installed container includes a qualification receipt bound to the bundle model identity and preparation build; reuse rechecks the model bytes and all four recorded numerical gates. This receipt is local evidence, not an upstream signature. If a cache is corrupt, use a fresh cache rather than silently trusting or overwriting it.

For manual conversion with [uv](https://docs.astral.sh/uv/) already installed:

```bash
uv run --frozen --python 3.12.15 scripts/convert-visual-model.py \
  --source "$HOME/Library/Caches/OSwind/siglip2-source" \
  --output "$HOME/Library/Caches/OSwind/siglip2-native" --download
```

This explicitly installs the pinned Python conversion dependencies and downloads approximately 1.5 GB of original public weights plus tokenizer/config files. It uses no Hugging Face credential. Omit `--download` for source verification and conversion with no model fetch. Python is used for preparation and evaluation; native inference uses Swift/Core ML and does not require Python or a model server.

The output must be new. An abruptly interrupted download can leave `.partial` files for inspection; manual conversion refuses them by default. `--retry-partials` explicitly restarts bounded, owned regular partial files and safely recovers a verified target/partial publication pair. Symlinks, unrelated hard links and extra unverified source files are refused. The converter retains an adjacent `.conversion` directory containing packages, original-reference fixtures and numerical results. Preserve it for verification, then remove it manually if desired. The app retains the qualification receipt with the installed model and cleans its conversion scratch. Do not place conversion jobs inside a memory library or an encrypted vault if you intend them to remain available while that vault is locked.

A successful conversion publishes `OSWIND-VISION.json` only after both encoders pass the fixed numerical gate under CPU-only and CPU/GPU policies. The app validates the file inventory and hashes before model loading. The model identity hashes the entire manifest, so different compiled artifacts cannot silently share vectors. This is local integrity evidence, **not a signature or an attestation from Google**. Treat the selected bundle as immutable while loaded; release and reload after replacing it.

## Inspect and probe

```bash
.build/release/oswindctl vision status --model-dir /absolute/model/bundle
.build/release/oswindctl vision probe /absolute/fixture.json \
  --model-dir /absolute/model/bundle --compute cpuAndGPU
```

The fixture contains `queries` (strings) and `images` (absolute local file paths). The probe emits token IDs, normalized embeddings, text/image cosine similarities and timings to stdout. **Its output contains information derived from the supplied inputs; keep real-history probes private.** It never opens an OSwind library, reads saved provider keys, starts capture or contacts a model service. It is a developer qualification surface, not a visual-search UI.

For numerical diagnosis, `--pixel-output /absolute/NEW-directory` explicitly exports private, little-endian Float32 NCHW inputs as `input-N.f32`. These arrays contain the decoded image content. The directory must be new and outside the model bundle. Ordinary inference writes no image scratch; this diagnostic export is optional and must remain private for real inputs.

Only upright, single-frame images of at most 16 megapixels / 64 MiB are admitted. ImageIO decodes into sRGB; transparency is composited onto white. The native resize matches the pinned Pillow antialiased bilinear convention, then converts to 224×224 normalized NCHW RGB. Exact byte fixtures cover eight resize shapes. Arbitrary ICC profiles, HDR, EXIF rotation and transparent images are outside the exact PyTorch pixel-parity claim; rotated input is rejected. Retained desktop images are normally opaque and upright.

The tokenizer preserves case, whitespace and Unicode composition. Queries are limited to 32 KiB, truncated to 63 content tokens, terminated with EOS=1 and right-padded with PAD=0 to 64 positions. Truncation is reported. Do not lowercase, trim or apply a CLIP prompt template silently. SigLIP's final pooled position makes padding part of the model contract.

## Precision and lifecycle

The first full-FP16 image candidate failed the CPU numerical gate: minimum cosine agreement **0.98236**, below **0.999**. Tracing itself matched the original model. Full-FP32 image compute passes both tested policies. Keeping only layer normalization/softmax/reductions in FP32 did not repair the CPU discrepancy. The initial recipe therefore uses **FP32 image compute and FP16 text compute**. The failed measurements are retained in the qualification evidence; the gate was not relaxed.

`VisualEncoder` serializes inference, shares a generation-fenced load, rejects a conflicting preparation, and supports idle release / explicit release. Explicit release cancels and awaits outstanding preparation so stale work cannot repopulate the cache. Inference already executing finishes before the actor can release it; cancellation is checked before and after Core ML prediction. Encoders and tokenizer are released together; model files remain. No image temporary file is written.

CPU/GPU is the default allowed compute policy, with an explicitly tested CPU-only alternative. A Core ML static plan on this M5 Max prefers GPU for all 307 image and 285 text operations with CPU/GPU enabled. This is not an observed GPU hardware trace, ANE qualification, energy measurement or support claim for every Mac. Minimum macOS 14 is the model/API deployment target; this qualification ran on macOS 26.6.2.

## Reproduce qualification

```bash
python3 scripts/test-visual-model-tools.py
python3 scripts/visual-preparation-catalog.py --check
# Offline package contracts; requires an already qualified public-model cache:
python3 scripts/visual-preparation-smoke.py /absolute/OSwind.app \
  --cache-root /absolute/qualified-cache --root /absolute/NEW-contract-directory
OSWIND_VISUAL_MODEL_DIR=/absolute/model/bundle swift test --filter VisualEncoderTests
uv run --python 3.12 scripts/evaluate-visual-model.py --prepare \
  --work /absolute/new-evaluation-directory
uv run --python 3.12 scripts/evaluate-visual-model.py \
  --work /absolute/new-evaluation-directory --cli /absolute/oswindctl \
  --model-dir /absolute/model/bundle --source /absolute/pinned-source
```

The evaluator downloads official COCO annotations over certificate-verified HTTPS through the dataset's S3 bucket and checks the public TensorFlow Datasets [annotation checksum](https://raw.githubusercontent.com/tensorflow/datasets/master/tensorflow_datasets/url_checksums/coco_captions.txt). It selects 100 validation images using seed 1729 and runs their captions through the native CLI and original local PyTorch model. It reports both retrieval directions, tokenizer/numerical agreement, timings and peak process RSS. Images, captions and raw vectors remain in the private work directory; only sanitized aggregate evidence is published.

The first natural-photo run failed an end-to-end 0.999 cosine gate (worst 0.9909), despite identical aggregate retrieval scores. All eight worst cases agree above 0.9999999 after both runtimes receive the same decoded RGB pixels. Native ImageIO/sRGB decoding differs from Pillow's JPEG/ICC handling. The revised evaluator therefore exports the actual native input tensors and measures **encoder** agreement against PyTorch on those identical tensors. It separately retains the original Pillow pipeline agreement and both retrieval baselines. The original failed report remains evidence; no full JPEG-pipeline equivalence or lowered encoder threshold is claimed.

This small photo subset is **not the standard COCO 5k benchmark, a desktop-history relevance study, a proven unseen training holdout or a comparison with competitor apps**. It establishes a local implementation baseline. No threshold is tuned against its labels.

## Integration and remaining gates

[Visual search](VISUAL-SEARCH.md) now connects source/media/frame identities, privacy rules, private replay workspaces, persisted vectors, scoped CLI/HTTP/MCP queries, protected previews, matched-time opening, native settings, background catch-up and backup/restore. These are separate from the frozen encoder-only measurements above.

One-click preparation is implemented and exercised through the CLI. Native click/keyboard acceptance, byte-range resume, labeled desktop relevance, cold starts, realistic archive scaling, energy and matched competitor measurements remain open. Visual similarity does not establish a caption or factual image-grounded Ask answer.
