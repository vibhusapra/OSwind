# Local chat presets and setup routing

Runtime `b7c91ec` uses `qwen3.5:4b` for a fresh local chat configuration and offers `gemma4:e4b` as a larger download preset. The preset buttons fill the download field; users then choose the installed model in Answer engine. Existing saved model names are preserved. Download completion does not mean the model is loaded for its first answer.

The setup script explicitly sets `OLLAMA_HOST=127.0.0.1:11434` and `OLLAMA_NO_CLOUD=1` for both server startup and model pulls. An ambient remote host cannot redirect these commands. Explicit chat/embedding model-name overrides still work. Whisper installation and verification, embedding defaults, prompts, generation parameters and storage formats are unchanged.

The [receipt](../benchmarks/local-model-presets-v1.json), [input manifest](../benchmarks/local-model-presets-inputs-v1.json) and [raw evidence](../benchmarks/local-model-presets-raw-v1.zip) bind **703 committed inputs**. Five source/setup/CI files change; 698 of the 700 preceding runtime/test/dependency inputs remain unchanged. Qualification completed without a restart:

| Check | Result |
|---|---|
| Full Debug | 2,581 passed, 162 conditional skips, zero failures |
| Focused Thread Sanitizer | 136 passed, one conditional skip, zero failures/race diagnostics |
| Focused optimized | The same 136 passed and one skip, zero failures |
| Offline setup routing | Three new controls pass; the original script fails all three under the same inert remote-host fixture |
| Production build and fresh package | Pass; strict ad-hoc signature verified; preceding resources and bundle information unchanged |
| Actual packaged local requests | Two responses; fresh default and explicit legacy model both verified on the wire |
| Altered-log rejection | Five altered logs rejected |

The full Swift method identities and states exactly match the preceding qualified full suite. No new Swift methods are added. The three Python controls use inert executables: no installer, model download or inference runs in those controls. Their completed logs are adopted by hash rather than repeated for publication, and CI now selects them.

The packaged check uses two separate fictional one-note libraries and omits `--model` from both requests. An owned loopback recorder forwards only local tags/chat requests to the existing local Ollama service. The fresh configuration requests Qwen3.5; the saved configuration requests `qwen3:4b-instruct-2507-q4_K_M`. Both responses contain the exact stored source ID/text; settings bytes remain unchanged and no Authorization header is sent. The recorder shuts down and joins. This is routing/configuration evidence, not an answer-quality score or GUI click test.

The separate [96-attempt model comparison](LOCAL-MODEL-COMPARISON.md) uses the earlier unchanged `49f259d` runtime. Its successful runs, reviewer, publisher and outputs remain frozen. This preset patch does not rerun that comparison or imply identical quality/performance under every deployment. All 485 preceding published benchmark/feature/landscape files remain unchanged.

At this preset runtime, model-library discovery/download controls still use the search endpoint. Defaults share the same loopback server. The later [endpoint-aware model library](MODEL-LIBRARY-ROUTING.md) addresses independently configured chat/search servers under its own qualification. Model startup delays, remaining citation-support failures and observed refusals are retained in the comparison report.

All 83 feature statuses remain unchanged. GUI/TCC and older-Mac acceptance, physical capture and energy, complete sync and signed/notarized distribution remain open. This patch does not establish full v0 completion or a competitive product ranking.
