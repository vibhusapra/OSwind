# Architecture

Swift package targets:

- `OSwindCore`: durable store, privacy policy, embeddings/retrieval, model adapters, screen/audio capture, API and MCP protocol.
- `OSwind`: SwiftUI app, AppKit menu/shortcut integration, setup/settings, source browsing.
- `OSwindCLI`: `oswindctl`, diagnostics, imports, benchmark, API/MCP host.
- `CSQLite`: system sqlite3 shim only. No fetched Swift dependencies.

## Screen ingest

Foreground context → lock/idle/secure-field/app/title/URL checks → ScreenCaptureKit focused-window snapshot → small grayscale change signature → off-main Vision OCR → combine bounded Accessibility text → sanitize → suppress raw image if any text/title/URL was redacted → local embeddings → SQLite insert/FTS trigger → UI refresh.

One capture can be in flight. Pause/lock increments a generation token; in-flight work checks it before insert and deletes its image on cancellation. Full-display mode filters excluded apps and all browsers. Redaction is not a comprehensive DLP model. OS permission and URL extraction behavior need live testing per supported browser.

## Retrieval

Keyword queries are tokenized into quoted FTS terms (no raw SQL/FTS syntax). Date/app/kind/favorites/tag filters are SQL-bound parameters. Semantic search reads same-model, same-dimension vectors, computes Accelerate cosine scores and applies a minimum similarity. Apple Hybrid uses reciprocal-rank fusion (k=60). Optional Ollama embedding search uses cosine plus a bounded lexical-coverage bonus, preserving strong cross-language matches. Its Qwen3 query prefix follows the publisher instruction format. Semantic vector scanning is exact and linear, so large archives need ANN or partitioned candidates; benchmark scale before replacing it.

Memory JSON payloads store source metadata; embeddings are separate float32 blobs. Schema 2 adds a multi-model vector table keyed by memory ID and model identity (name, digest, preprocessing version and dimensions). Existing Apple vectors remain readable without reprocessing. Metadata edits preserve vectors; content changes invalidate the extra indexes. Network inference occurs outside SQLite locks, and batch saves compare content hashes to avoid storing stale results or resurrecting deleted records. Resumable 16-record batches retain completed work on cancellation. Automatic indexing is bounded and defers under low-power policy.

`RetrievalEngine` supplies one async search path to UI, Ask, CLI, HTTP and MCP, including coverage and fallback warnings. Keyword queries require no model server. Hybrid falls back explicitly to keyword search on model failure; semantic-only reports the failure. Local model URLs are loopback-only, redirects are refused and known remote/cloud model aliases are rejected before evidence is sent. These checks assume a trusted local daemon. OSwind-managed Ollama servers set `OLLAMA_NO_CLOUD=1`; an existing user daemon is not replaced or reconfigured.

Model discovery, streaming pulls, cancellation and GPU memory residency use Ollama APIs. Local generation and retrieval select independent models. The model manager starts an installed runtime; dependency installation remains in the setup script. No weights are bundled in Git.  SQLite WAL handles external readers. A process-local recursive lock serializes store operations. JSON imports run in a transaction, strip media paths, apply exclusions/redaction and rebuild vectors. Media paths reject traversal and symlink components and must live under `images/` or `audio/`.

## Audio

Microphone AVAudioEngine → AVAudioConverter to 16 kHz mono PCM. System audio SCStream → mono PCM. Each source accumulates a 30-second chunk. A simple RMS gate discards silence. At most three pending chunks; one whisper.cpp subprocess drains them with a time limit. Raw chunks are deleted after processing. Source labels remain distinct. Explicit Stop audio flushes a short final chunk; privacy Pause discards it and cancels pending inference. A one-second privacy timer stops audio when an excluded foreground context or lock is detected. Diarization, automatic meeting detection, audio-device changes and stronger continuous privacy tracking remain gaps.

## Answers

Query + date/app filters → up to 12 evidence memories → bounded text excerpts → evidence-only, Apple FoundationModels, local Ollama, or explicit remote BYOK. Prompt separates untrusted source text and requests citations. Source cards are authoritative evidence; model prose must be checked. No agent tools or external writes are available to the answer engine.

## Release risks

Current store schema is version 2, with a version-1 preservation fixture. Future schema changes require migrations and fixture coverage. App binaries are locally ad-hoc signed, with no notarization/update service. Apple English sentence embeddings remain the default zero-download baseline. Optional Qwen3 multilingual results are measured on a small authored fixture; multimodal retrieval and robust no-evidence abstention remain gaps. Long-run power, pressure, permission revocation, audio hardware changes, and adversarial privacy testing require broader validation.
