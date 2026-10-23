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

Search fields: `app`, `kind` (`screen`, `audio`, `note`, `summary`), `start` and `end` (ISO 8601, inclusive start/exclusive end), `favorites=true`, `tag`, `limit` (1–100), `mode` (`hybrid`, `keyword`, `semantic`). Returned dates are ISO 8601. Assets are relative paths, not served over HTTP. HTTP and MCP search return an envelope: `{ "hits": [...], "warnings": [...], "modelID": "..." | null, "duration": 0.1 }`. `duration` is seconds. Clients should show warnings for partial index coverage and Hybrid keyword fallback. Semantic-only returns an error if the selected model is unavailable. These paths read the store's `settings.json` search configuration; vectors must be built for the selected model first.

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

Only selected text evidence is sent to the selected model. No provider fallback occurs. Some compatible implementations do not accept all Chat Completions parameters; integration tests against named third-party providers remain outstanding.
