# Search retained images and replay frames

OSwind's optional visual mode embeds retained screenshots and each declared replay frame with local SigLIP2 Core ML models. It finds appearance without requiring OCR text. Results carry the model, preprocessing, source revision, file SHA-256 and actual matched-frame time. Open a match to inspect the recorded pixels. A similarity score is a ranking signal, not a calibrated confidence or a factual caption. Ask still uses recorded text; this feature adds no image-understanding claim to text-only answers.

## Set up

First [prepare the pinned local bundle](VISUAL-MODELS.md#prepare-once). The qualified bundle occupies about 969 MB. Conversion needs Python tooling; native indexing and search do not. The model is optional and is not included in the app. There is no automatic cloud fallback or credential lookup.

In **Settings → Models → Visual memory**, choose the prepared directory, enable visual memory, select CPU + GPU or CPU only, then **Build / resume visual index**. Automatic indexing handles new retained captures and catches up missing sources on startup/wake when power policy permits. The status reports indexed sources/frames, failures and coverage gaps. Text search works independently.

The same operations are available explicitly on the selected library:

```bash
oswindctl --data /absolute/library vision index \
  --model-dir /absolute/prepared-bundle --use-model
oswindctl --data /absolute/library search --mode visual --details \
  'a blue chart beside a photograph'
oswindctl --data /absolute/library vision search \
  --model-dir /absolute/prepared-bundle --app Safari --tag research \
  'a blue chart beside a photograph'
```

`--use-model` saves that local model choice and enables visual mode. A one-shot `vision search` can use `--model-dir` without changing settings. Generic CLI search, authenticated loopback `/v1/search?mode=visual`, and MCP `search_memory` with `mode: "visual"` use the saved configuration. HTTP and MCP include the same source/frame identity and warnings as CLI search.

App/date/kind/favorite/tag/speaker filters intersect the visual candidate set. Explicit quotes and Boolean expressions constrain **recorded text**, then appearance ranks those sources. Turn Query filters off / pass `--literal` for an ordinary description containing quotation marks or uppercase operators. An empty visual query browses recent supported sources without loading a model. Descriptive queries require explicit local setup; disabled or missing models produce a visible setup error.

## Index integrity and privacy

Schema19 stores visual sources, complete frame manifests and vectors separately from text embeddings. Model, preprocessing, retained media bytes, metadata context and frame plan determine identity. Source context changes invalidate derived vectors; tags and favorites preserve them. Resume verifies current bytes before reusing completed sources. A replay's poster cannot stand in for its frame coverage. Partial, cancelled or changed-source work cannot publish a ready manifest.

Current app/browser/domain/title privacy rules apply before inference and search. Missing browser context remains excluded under the existing policy. Capture-suppressed raw images are unavailable to visual indexing. Excluding an already indexed source hides it; rebuilding removes its derived group while retaining the original history according to the ordinary data policy. This is not a learned image-sensitive-content or complete PII filter.

Image bytes remain in RAM. Replay decoding pins an immutable clip under the library's private `video/.staging` workspace, including inside a managed encrypted volume. Cooperative reservations span source reading, inference and admission; release drops directory descriptors and temporary pins before library close/detach. Search and previews revalidate current media rather than pairing stale vectors with replacement pixels. Deletion, retention and full wipe cascade derived rows. Backups retain verified visual vectors; restore validates complete frame groups and remaps source revisions to restored media paths. Stale derived groups are counted and discarded while history is preserved. Restored model paths and automatic visual processing are disabled until trusted setup.

Background indexing respects Low Power Mode unless background indexing is allowed, and defers under serious/critical thermal pressure. Completed sources survive cancellation and power deferral. The queue is bounded, with explicit catch-up when it falls behind. Idle/manual release frees encoders and tokenizer; an indexing job holds one batch reservation across frame decoding, including with “After each use.” Disk model files remain. This policy has not established a battery-life or energy advantage.

## Qualification and remaining work

The [encoder evidence](../benchmarks/visual-encoder-v1.json) separates identical-tensor numerical agreement from the retained JPEG/Pillow decoding discrepancy. `benchmark-visual` measures the actual persisted index, source-validating retrieval, filters and reopen using explicit public/synthetic images. `scripts/visual-search-smoke.py` adds real CLI/HTTP/MCP identity, scope, authentication and changed-byte checks in a new isolated library. The [signed release trial](../benchmarks/visual-memory-v1.json) indexes 100 photos in 9.71 s, returns 459/501 correct top 1 and 498/501 top 5, and measures 14.27/16.10 ms median/p95 source-validating queries on one M5 Max. The process reaches 1.576 GB peak RSS. These fixtures bypass physical screen capture and do not establish desktop relevance or competitor superiority. Caches/background work are uncontrolled; no cold-start or energy claim is made.

Remaining gates include labeled desktop tasks, realistic long-archive media I/O, cold start, physical capture/energy, broader hardware/OS coverage, native keyboard/accessibility acceptance and one-click model preparation/download. Current replay indexing is bounded to 240 declared frames, 120 seconds, 4096-pixel video dimensions and 512 MiB per clip; retained images use the encoder's 16-megapixel / 64 MiB limits. Very large or malformed media are reported as failures. Exact source checks can be expensive for large clips. No ANN scaling or top-three claim is made for this visual path.
