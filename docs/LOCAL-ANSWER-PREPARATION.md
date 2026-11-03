# Load the selected answer model explicitly

Runtime `9245805` adds **Load selected answer model** in Settings → Models → Answer engine for Ollama. Choose the installed model, then load it without sending a question or captured evidence. The UI shows the admitted model/endpoint while loading, supports cancellation, and displays the server's memory observation and expiry. Loading is optional; capture and keyword search do not require it.

A download and a first answer can involve separate startup work. The earlier [model comparison](LOCAL-MODEL-COMPARISON.md) retains long first observed requests under uncontrolled conditions. This action makes model loading explicit. It does not establish a measured first-answer speed improvement or remove every initialization/compilation cost.

## Local request and identity

The client resolves one unambiguous installed model, refuses known cloud aliases and explicit non-completion capabilities, and requires a valid server-reported digest. It sends `model`, `stream: false`, `keep_alive: "5m"` and `options.num_ctx: 8192` to the loopback generate endpoint. There is no prompt, system message, evidence, image, audio or API key in this body. It never calls the pull/unload APIs or changes global runtime settings. This uses the documented [Ollama preload behavior](https://docs.ollama.com/faq#how-can-i-preload-a-model-into-ollama-to-get-faster-response-times) and [generate API](https://docs.ollama.com/api/generate).

The load and answer paths share the existing 8,192-token context value. A real loopback contract executes AnswerEngine and verifies both request envelopes use 8,192, while answer temperature 0.2, output limit 1,000 and disabled thinking remain unchanged. An acknowledged empty response alone is insufficient. The client rejects incomplete/wrong-model replies, generated text or nonzero reported evaluation counts. It rechecks installed identity and requires one matching model with positive reported memory, the expected 8,192-token context and a future expiry from the [running-model API](https://docs.ollama.com/api/ps). Untagged `:latest` resolution preserves the configured name; ambiguous names, retagging, invalid dates and mismatched/expired/context-incompatible residency fail without publishing a loaded state.

The app binds work to the selected **answer** model/endpoint even while the library shows the search server. Changing the answer selection cancels and invalidates the old result, including changing away and back to the same name. Independent search changes do not invalidate an answer load. Cancellation owns the task until it exits and keeps this controller's pull/start/load actions serialized during that time. App retirement and external-work drain include that task. Saved settings stay unchanged. Cancel stops this request and does not unload shared models; it does not establish that all server-side processing has stopped.

The UI describes a server observation. Its displayed validity is capped at five minutes and never extends beyond the reported expiry; it updates while the view is visible. The server can evict the model earlier, and a later answer may still need initialization. Reported memory is not per-operation processor-use evidence.

## Qualification and actual local observation

The [receipt](../benchmarks/local-answer-preparation-v1.json), [input manifest](../benchmarks/local-answer-preparation-inputs-v1.json) and [raw archive](../benchmarks/local-answer-preparation-raw-v1.zip) bind **711 committed inputs**. The complete feature changes eleven source/test files relative to PR156. The context follow-up changes eight files, preserving 703 of 711 bare-load implementation inputs. All twenty-one new identities are accounted for: twenty ordinary controls and one separately gated actual-model case.

| Check | Result |
|---|---|
| Full Debug | 2,611 passed, 163 conditional skips, zero failures |
| Focused Thread Sanitizer | 150 passed, 37 conditional skips, zero failures/race diagnostics |
| Focused optimized | 150 passed, 37 conditional skips, zero failures |
| Explicit actual local model · optimized | 1 passed, 0 skips; one model-load request |
| Fresh production package | Normal release build and strict ad-hoc signature pass; prior resources and bundle information unchanged |
| Altered evidence controls | Five altered logs and six altered live-observation records rejected |

In the final aligned qualification, the actual-model identity is intentionally skipped in ordinary selections. It runs once, explicitly configured, against existing local Ollama 0.40.8 through the app controller/client. Before/after server version and all five installed digests agree. No weights are downloaded; no user history/settings root or answer inference is involved.

| Actual observation | Retained value |
|---|---|
| Model | `qwen3.5:4b` |
| Server-reported digest | `7f3251fa6878a78a606bcb3c074283306e5ad2ea411a7774a9dd98a4bc7f2d13` |
| Selected model reported loaded before action | False |
| Client load/check elapsed | 31.818 seconds |
| Server load duration | Not reported for this empty request |
| Reported answer context | 8,192 tokens |
| Reported resident memory | 3,953,620,480 bytes |
| Reported GPU memory | 3,953,620,480 bytes |
| Observed / server expiry | 2026-11-03T14:36:46Z / 2026-11-03T14:41:46Z |

These are descriptive observations, with cache/order/host conditions uncontrolled. A missing server duration remains missing. They are not a controlled cold-start benchmark, a paired first-answer comparison, a semantic quality score, an energy result or a product ranking. The real service's wire body is not independently recorded; its shape is separately verified on two owned actual HTTP servers and request-protocol controls. The two-server test sees exactly one empty finite load at each selected destination and waits for listener/connection shutdown.

The full suite preserves all preceding method identities/states and adds twenty passes plus the gated skip relative to PR156. The preliminary helper access-control compile failure and request-spy body-stream failure are retained; the corrected spy captures actual bounded stream bytes. Formal final-source runs supply the qualification counts. All 495 preceding benchmark/feature/landscape publications and all earlier successful comparison/qualification artifacts remain unchanged.

## Separate packaged answer after loading

One new authored note states that Deya owns the fictional Harbor checklist. While the selected model is still reported resident with the 8,192-token context, the fresh packaged CLI asks who owns that checklist. It returns the expected owner and source citation in **0.396 seconds** of whole-process time. The source ID/stored text agree and settings bytes remain unchanged. Five altered owner/citation/source records reject. No extra explicit preload request or earlier benchmark is repeated.

This is one functional smoke observation, not a controlled paired latency improvement, an aggregate accuracy score or a product ranking. The archive retains the declared note/question, every output and the independent mechanical review. Server-internal processing is not independently observed.

## Retained context mismatch

The first implementation passed its bare-load checks, including one actual request, but reported a 262,144-token context. The answer engine already used 8,192. That first actual observation and all seven stages remain retained as insufficient answer-context acceptance. The final request explicitly uses the existing answer context and the final observation must report it. No previously successful request is repeated for metadata; the follow-up changes the runtime parameter and validates that change. The first reviewer's singular/plural test-summary bug and its corrected review are retained too.

No measured reload penalty or first-answer speed improvement is inferred from the mismatch alone. The fixture and live checks establish request/observation alignment. A server that cannot report matching context does not receive a load-confirmed state; this optional action does not disable ordinary answers.

## Remaining acceptance

GUI clicks/TCC, older-Mac behavior and managed child-process startup/exit remain separate. Complete sync, physical capture/energy and signed/notarized distribution remain open. All 83 feature statuses remain unchanged; full v0 completion and a top-three ranking are not established.
