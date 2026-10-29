# API and MCP

The app and CLI use the same local SQLite store. Other processes can read it concurrently through WAL. Run only trusted clients: recorded material is untrusted source content and can include prompt injection.

## Loopback HTTP API

Enable in app Settings → Connect, or run:

```bash
swift run oswindctl serve
```

The server binds to `127.0.0.1:47831` only. Every request, including health, requires `Authorization: Bearer TOKEN`. The token is generated from 32 cryptographic random bytes and saved at `~/Library/Application Support/OSwind/api-token` with mode 0600. Browser Origin headers are rejected. CORS is not enabled. No mutations, answer generation, shell execution or external integrations are exposed. Semantic/Hybrid search can call the configured loopback embedding server; keyword mode has no model dependency.

- `GET /health`
- `GET /v1/stats`
- `GET /v1/activity?month=2024-11&day=2024-11-03&timeZone=America%2FNew_York`
- `GET /v1/search?query=release&mode=hybrid&limit=20`
- `GET /v1/memories/{id}`

Search fields: `app`, `kind` (`screen`, `audio`, `note`, `summary`), `start` and `end` (ISO 8601, inclusive start/exclusive end), `favorites=true`, `tag`, `speaker` (recording-local name), `detail` (`full` or `preview`), `limit` (1–100), `mode` (`hybrid`, `keyword`, `semantic`). Time filters also include bounded sampled text spans. Set `sourceStartsOnly=true` (HTTP) or `sourceStartsOnly: true` (MCP) to match starts only; values must be Booleans and HTTP accepts only `true`/`false`. Returned dates are ISO 8601. Assets are relative paths, not served over HTTP. HTTP and MCP search return an envelope: `{ "hits": [...], "warnings": [...], "modelID": "..." | null, "duration": 0.1, "strategy": "exact" | "ann-exact-rerank" | null }`. `duration` is seconds. Clients should show warnings for partial index coverage and Hybrid keyword fallback. Semantic-only returns an error if the selected model is unavailable. These paths read the store's `settings.json` search configuration; vectors must be built for the selected model first.

CLI search prints the hit array by default, with warnings on stderr. Add `--details` for the same envelope. The HTTP header deadline is separate from model inference timeouts.

## MCP stdio

```json
{
  "mcpServers": {
    "oswind": {
      "command": "/Applications/OSwind.app/Contents/MacOS/oswindctl",
      "args": ["mcp"]
    }
  }
}
```

For an isolated database use `args: ["--data", "/absolute/data/path", "mcp"]`.

Tools: `search_memory`, `get_memory`, `memory_stats`, `memory_activity`. Search arguments match the HTTP fields, except `favorites` is a Boolean and `limit` an integer. Supports newline-delimited JSON-RPC over stdio and negotiates protocol versions 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25. Only protocol responses go to stdout. OS user/file access is the stdio authorization boundary; the HTTP token is not used by stdio.

Configure a trusted client yourself in its supported configuration. OSwind does not silently add itself to other applications.

## Calendar counts

HTTP `/v1/activity` and MCP `memory_activity` count all saved sources in a Gregorian month, with optional selected-day hour buckets. Accept `month` (required), `day`, `timeZone`, `firstWeekday` (Sunday=1), and metadata scopes `app`, `kind`, `favorites`, `tag`, `speaker`, `start`, `end`. They reject search text, relevance modes and result limits. Counts are sources, not duration or recording coverage. Repeated clock hours have distinct UTC boundaries and offsets. See [calendar semantics and examples](ACTIVITY-CALENDAR.md).

## BYOK

The app stores keys under Keychain service `com.oswind.secrets`, accounts `compatible` and `anthropic`. The settings JSON contains no keys. Model requests use ephemeral URL sessions, reject HTTP redirects, require HTTPS for remote endpoints and explicit remote context permission. Local Ollama mode accepts only loopback endpoints. Use a base URL ending in `/v1` for OpenAI-compatible chat servers; OSwind appends `/chat/completions`. Anthropic mode expects a base URL such as `https://api.anthropic.com` and appends `/v1/messages`.

The current question and selected text evidence are sent to the selected generation model. Recent user questions affect retrieval/excerpt selection, rather than being repeated in the generation prompt. Earlier generated answers are not used as evidence. No provider fallback occurs. Some compatible implementations do not accept all Chat Completions parameters; integration tests against named third-party providers remain outstanding.

## Local conversations (CLI)

`chat new`, `chat list`, `chat show ID`, `chat ask ID QUESTION`, `chat export ID PATH` and `chat delete ID` manage durable sessions. `chat ask` accepts `--provider`, `--model`, `--endpoint`, app/kind/date/tag/favorite search flags and uses the configured search model. Each successful turn is saved atomically; failed/cancelled inference saves no completed turn. `show` returns the session plus hydrated turns. Exports are Markdown with question/answer blocks, provider, scope and source references, created with mode 0600. Chat history is not exposed through HTTP/MCP.

The UI reads the most recent 100 turns per session; CLI show/export read up to 1000. These bounds are explicit v0 limits, not unlimited-history claims. Source erasure/revision removes derived turns; copied/exported text and explicitly saved recap notes are independent files/records.


## Indexed retrieval

Settings → Models offers Automatic, Exact and Indexed. CLI `index-search --model qwen3-embedding:0.6b --use-index` prepares a native cache and explicitly selects Indexed after success; run `reindex --model … --use-model` first if vectors are missing. The shared configured strategy applies to CLI, UI, Ask, HTTP and MCP. Approximate candidates are reranked against live SQLite vectors, with current filters and revision checks. `strategy` records the actual path; warnings explain exact fallback. Automatic uses exact search for filtered/small scopes. Indexed is an explicit approximation choice, not an exactness guarantee. API authentication and read-only behavior are unchanged. `python3 scripts/integration-smoke.py .build/release/oswindctl --indexed` exercises real CLI/MCP/HTTP processes with an offline local-model fixture.


`ask` also accepts explicit local model/endpoint and scope flags. `python3 scripts/chat-provider-smoke.py .build/release/oswindctl` checks these overrides, current-question prompts, output-limit failure and absence of partial chat persistence using an offline Ollama fixture. It makes no paid provider request and uses no BYOK secret. Provider output-limit reasons (`length`, `max_tokens`, `model_length`) are errors; a partial answer is not persisted. A model can still produce a wrong claim with a valid citation or finish without exposing a recognized stop reason; structural validation is not semantic support checking.


## Long-transcript search previews

Complete records remain the default. For lighter browsing, request HTTP/MCP `detail=preview` or CLI `search --preview`. Timed audio results retain the **complete original text** and normal source metadata but omit the full `transcript` object and its timed segment array. An explicit `memory.searchPreview` contains `sourceRevision` and a transcript summary: duration, recognizer model, segment/assigned counts, speaker count, up to 32 exact local labels and `labelsComplete`. Labels above the per-label byte bound are omitted rather than shortened. Untimed audio and other memory kinds can remain complete.

Read one complete source with CLI `get ID`, MCP `get_memory`, or `GET /v1/memories/{id}`. Swift clients can call `MemoryStore.hydrate` to load complete sources while revalidating the preview's evidence revision and original UTF-16 passage offsets. Deleted/revised evidence fails explicitly; favorite/tag changes can hydrate with current metadata. Preview values cannot be inserted as complete sources, imported as original records, or saved directly as chat evidence. Normal exports and backups keep complete source transcripts; restore rebuilds the derived cache.

The app uses previews for result lists and hydrates a selected source away from the UI thread. Cancel, newer selections, source deletion and library switching discard late results. The answer engine previews candidate records, then hydrates the selected evidence before building speaker annotations or calling a model. Recaps rank thin timeline IDs before fetching sampled sources. These optimizations remove timed-array decoding from candidate browsing; raw text remains in results, and tag-filter parsing/large history hydration still need separate performance work.

```bash
oswindctl --data /path/to/library search --preview --mode keyword archive
oswindctl --data /path/to/library get MEMORY_ID
```

Schema 11 builds the cache one audio source at a time during migration, within the migration transaction. Source, name-index and preview writes are atomic. Metadata changes reserve the SQLite writer before reading a source so concurrent attribution edits cannot be overwritten by stale favorite/tag updates.

Sampled text sources can include `textObservation` (version, sessionID, samples, largestGapSeconds) and `endTimestamp` for their last sample. Gaps are unobserved; this is not continuous activity or a native-capture/privacy attestation. Calendar responses expose `timeBasis: "source-start"` and `scope.sourceStartsOnly: true`. See [sampled spans](TEXT-OBSERVATION-SPANS.md).
