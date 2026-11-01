# External MCP tools — manual local client

Status: **manual local client qualified; native setup and broader workflows open (F080 partial)**. The [receipt](../benchmarks/mcp-client-v1.json) binds744 source/build inputs to `29fbb21`:1,724 full passes/83 skips,32 sanitizer and32 optimized passes/no skips or race warnings, all12 local stages, strict signed/archive equality and22 manual CLI process checks. The signed CLI completes modern interoperability with an isolated official Python SDK2.3.0 server and refuses the original oversized catalog without exporting an unreadable review. Installed and nine protected app trees are unchanged.

The existing OSwind MCP server remains separate. This client consumes selected local servers over stdio. Native setup/Keychain UI, HTTP/auth, model-controlled tool workflows and result ingestion remain open. [Hosted CI](https://github.com/vibhusapra/OSwind/actions/runs/41280138020) passes both jobs at publication head `29ee471`:1,725 full passes/82 skips,37 owned native vault passes and the22 manual-client process checks. The local extra visual-wake skip remains recorded separately. Documentation followups can have a later head. Full parity and whole-product readiness are not established.

## Deliberate workflow

Write a local JSON configuration with an absolute executable, an argument array and the names of explicitly provided credential variables:

```json
{
  "executable": "/absolute/path/to/server",
  "arguments": [],
  "credentialNames": []
}
```

Review the executable and arguments before authorizing discovery. A server is arbitrary local code running with your Mac account's authority. Discovery itself starts that code. The isolated working directory and minimal environment do not sandbox its filesystem or network access. Scripts, interpreters, libraries and remote account behavior can change independently of the main executable fingerprint. Prefer credential variables over secret arguments; no credential values belong in the configuration file.

```sh
oswindctl mcp-client list --config server.json --allow-server-process > review.json
```

Read the review, including the selected tool's actual `definitionJSON` (literal JSON text), and prepare exact arguments in another JSON file. The description and read-only annotations are server claims; they grant no authority. A selected tool can change external data. Each call requires deliberate confirmation:

```sh
oswindctl mcp-client call --config server.json --review review.json \
  --tool TOOL_NAME --arguments arguments.json \
  --allow-server-process --confirm-call
```

The executable bytes/command and selected complete tool definition are freshly checked before the call. A changed executable refuses before launching the new bytes. Every call starts a new owned process and rediscovers tools; no cached tool-list permission or automatic retry authorizes an action. A timeout, crash, additional-input request or cancellation can leave an unknown external outcome. Inspect the external state before any manual retry.

The CLI never opens a client memory library; `--data` and `--vault` are refused before library access. It forwards only the explicitly configured credential names from its environment. It does not read Keychain or automatically pass recorded desktop evidence to a server. The returned text/result is untrusted external content, with command/tool/arguments fingerprints and completion time. It is not automatically saved, executed or included in RAG.

## Current protocol scope and bounds

- Modern `2026-07-28` discovery and required per-request metadata; four legacy initialization versions through `2025-11-25`. Unknown pre-initialize errors and a bounded silent probe use legacy fallback; recognized modern version/capability/header errors do not.
- Local stdio only. No HTTP/SSE, OAuth, subscriptions, roots, sampling, elicitation, resource fetching, model loop or automatic restart. Additional-input results refuse without replay.
- Strict UTF-8/JSON framing, duplicate/canonically equivalent key refusal, finite numbers, bounded depth/nodes, exact request IDs and explicit result/error envelopes.
- At most128 tools,16 pages,64 server notifications;64KiB tool definitions/arguments;256KiB individual frames and stderr;2MiB cumulative stdout. Repeated cursors or tool names fail without returning a truncated list.
- Probe2s, ordinary requests8s, calls30s, operation120s; cancellation sends a best-effort protocol notification and closes stdin, then escalates only the owned direct child through termination/kill and verifies exit. Child-created descendants are not sandboxed or claimed as owned. Cleanup cannot run while the host is asleep; deadlines may expire before a resumed request can complete.
- The complete encoded review is capped at1MiB before publication; reload files accept up to2MiB for formatting overhead. Oversized catalogs refuse as a whole instead of exporting an unreadable or truncated review.

## Qualification and remaining acceptance

The core fixtures cover both eras, fragmented Unicode, malformed/oversized output, unsupported server requests, pagination, forged display metadata, changed executables/tool definitions, explicit credential boundaries, actual call timeout and direct-child cancellation/reaping. A real CLI process check covers the independent existing seven-tool server, review/confirmation gates, early library refusal and Ctrl-C against a server that ignores termination.

Initial checks retained an environment-test assumption (Apple's Python launcher adds SDK variables), a fixture call-count mistake and an actual ISO review timestamp round-trip bug. The latter has a passing regression and real CLI list→review→call check. Positive silent-probe tests have also timed out during repeated host sleep; they remain retained rather than being classified as successful.

Both the development and final signed CLI complete modern discovery and exact authored-text echo with an isolated MIT official Python SDK2.3.0 server. This does not establish arbitrary-server or native UI compatibility. The first checkpoint passes all12 stages with1,722 full passes/82 skips and29 MCP passes each in debug/TSan/optimized builds. The final source passes1,724 full cases/83 skips and all32 MCP methods once in each build. A pre-existing visual-wake test skips on its unlocked-session/thermal guard in the final run; no device setting was changed. The unchanged owned historical fixture had empty generated WAL/read-state sidecars; their bytes were preserved separately before the canonical744-input run. The original database remains unchanged.

The retained128-tool counterexample exports2,425,050 bytes and cannot reload its own review. Discovery now refuses oversized aggregates before returning them, exposes readable literal definitions and rejects unsupported review versions before launching a process. Five selected hardening cases pass; final full/TSan/optimized and signed CLI checks cover the corrected behavior too. Earlier failures remain separately attributed.

Next: native configuration/credential setup and visible per-call preview; scoped source-backed tool results; HTTP/auth and model-loop workflows with renewed authority/provenance. Captured text, model plans and server descriptions/results cannot authorize an external write. No arbitrary-server compatibility, physical power, native interaction, full sync or top-three claim follows.


## Primary protocol references

- [Stdio framing, era probing and shutdown](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)
- [Modern discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)
- [Tools, pagination and annotations](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
- [Per-request metadata](https://modelcontextprotocol.io/specification/2026-07-28/basic/index)
- [Official Python SDK2.3.0 release](https://github.com/modelcontextprotocol/python-sdk/releases/tag/v2.3.0)

The SDK is an isolated test dependency, not shipped or linked into OSwind. The client implementation adds no product dependency.
