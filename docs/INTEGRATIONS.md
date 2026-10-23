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
- `GET /v1/search?query=release&mode=hybrid&limit=20`
- `GET /v1/memories/{id}`

Search fields: `app`, `kind` (`screen`, `audio`, `note`, `summary`), `start` and `end` (ISO 8601, inclusive start/exclusive end), `favorites=true`, `tag`, `limit` (1–100), `mode` (`hybrid`, `keyword`, `semantic`). Returned dates are ISO 8601. Assets are relative paths, not served over HTTP. HTTP and MCP search return an envelope: `{ "hits": [...], "warnings": [...], "modelID": "..." | null, "duration": 0.1, "strategy": "exact" | "ann-exact-rerank" | null }`. `duration` is seconds. Clients should show warnings for partial index coverage and Hybrid keyword fallback. Semantic-only returns an error if the selected model is unavailable. These paths read the store's `settings.json` search configuration; vectors must be built for the selected model first.

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

Tools: `search_memory`, `get_memory`, `memory_stats`. Search arguments match the HTTP fields, except `favorites` is a Boolean and `limit` an integer. Supports newline-delimited JSON-RPC over stdio and negotiates protocol versions 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25. Only protocol responses go to stdout. OS user/file access is the stdio authorization boundary; the HTTP token is not used by stdio.

Configure a trusted client yourself in its supported configuration. OSwind does not silently add itself to other applications.

## BYOK

The app stores keys under Keychain service `com.oswind.secrets`, accounts `compatible` and `anthropic`. The settings JSON contains no keys. Model requests use ephemeral URL sessions, reject HTTP redirects, require HTTPS for remote endpoints and explicit remote context permission. Local Ollama mode accepts only loopback endpoints. Use a base URL ending in `/v1` for OpenAI-compatible chat servers; OSwind appends `/chat/completions`. Anthropic mode expects a base URL such as `https://api.anthropic.com` and appends `/v1/messages`.

The current question and selected text evidence are sent to the selected generation model. Recent user questions affect retrieval/excerpt selection, rather than being repeated in the generation prompt. Earlier generated answers are not used as evidence. No provider fallback occurs. Some compatible implementations do not accept all Chat Completions parameters; integration tests against named third-party providers remain outstanding.

## Local conversations (CLI)

`chat new`, `chat list`, `chat show ID`, `chat ask ID QUESTION`, `chat export ID PATH` and `chat delete ID` manage durable sessions. `chat ask` accepts `--provider`, `--model`, `--endpoint`, app/kind/date/tag/favorite search flags and uses the configured search model. Each successful turn is saved atomically; failed/cancelled inference saves no completed turn. `show` returns the session plus hydrated turns. Exports are Markdown with question/answer blocks, provider, scope and source references, created with mode 0600. Chat history is not exposed through HTTP/MCP.

The UI reads the most recent 100 turns per session; CLI show/export read up to 1000. These bounds are explicit v0 limits, not unlimited-history claims. Source erasure/revision removes derived turns; copied/exported text and explicitly saved recap notes are independent files/records.


## Indexed retrieval

Settings → Models offers Automatic, Exact and Indexed. CLI `index-search --model qwen3-embedding:0.6b --use-index` prepares a native cache and explicitly selects Indexed after success; run `reindex --model … --use-model` first if vectors are missing. The shared configured strategy applies to CLI, UI, Ask, HTTP and MCP. Approximate candidates are reranked against live SQLite vectors, with current filters and revision checks. `strategy` records the actual path; warnings explain exact fallback. Automatic uses exact search for filtered/small scopes. Indexed is an explicit approximation choice, not an exactness guarantee. API authentication and read-only behavior are unchanged. `python3 scripts/integration-smoke.py .build/release/oswindctl --indexed` exercises real CLI/MCP/HTTP processes with an offline local-model fixture.


`ask` also accepts explicit local model/endpoint and scope flags. `python3 scripts/chat-provider-smoke.py .build/release/oswindctl` checks these overrides, current-question prompts, output-limit failure and absence of partial chat persistence using an offline Ollama fixture. It makes no paid provider request and uses no BYOK secret. Provider output-limit reasons (`length`, `max_tokens`, `model_length`) are errors; a partial answer is not persisted. A model can still produce a wrong claim with a valid citation or finish without exposing a recognized stop reason; structural validation is not semantic support checking.
