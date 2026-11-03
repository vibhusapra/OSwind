# Choose the local model server explicitly

Runtime `3128608` makes the local model library follow an explicit **Answer server** or **Search server** destination, with its concrete endpoint visible. Previously discovery, startup and downloads always used the search endpoint, and both model pickers shared its results even when chat used a different server.

Discover answer models and Discover search models target their respective configured servers. Each installed-model picker uses only that endpoint's snapshot. Two roles using the exact same endpoint share the discovered list. Editing endpoints invalidates affected snapshots and in-flight publications; late successes and errors cannot replace a newer check, including after an endpoint is changed away and back. A runtime-telemetry failure retains a successful installed-model list and displays a separate warning.

Downloads retain their admitted model name and endpoint even if settings or the selected role change. Progress identifies the actual destination. Cancel keeps the operation busy until its task exits, suppresses late progress/success, and prevents a second overlapping pull. The outcome says that the request was cancelled; it does not claim to control every server-side operation. Download completion still requires selecting the model and may precede first-answer startup.

The controller owns inspection, startup and pull tasks. App retirement cancels them; external-work drain waits for their task completion, and pending model work participates in app exit admission. These operations do not read captured evidence or mutate saved model selections. Starting a server uses existing loopback/cloud guards and never adopts an existing user's process. The existing runtime manager can own one newly started server at a time; additional independent servers must already be running or be started externally.

## Qualification

The [receipt](../benchmarks/model-library-routing-v1.json), [input manifest](../benchmarks/model-library-routing-inputs-v1.json) and [raw archive](../benchmarks/model-library-routing-raw-v1.zip) bind **706 committed inputs**, with **701 of 703 preceding inputs unchanged**. Five source/test files change and ten new method identities are accounted for.

| Check | Result |
|---|---|
| Full Debug | 2,591 passed, 162 conditional skips, zero failures |
| Focused Thread Sanitizer | 130 passed, 36 conditional skips, zero failures/race diagnostics |
| Focused optimized | 130 passed, 36 conditional skips, zero failures |
| Fresh production package | Normal release build and strict ad-hoc signature pass; preceding resources and bundle information unchanged |
| Altered-log controls | Five altered logs rejected |

The full suite preserves every preceding Swift method identity/state and adds the ten passing methods. Controlled operations exercise distinct routing, shared/different endpoint snapshots, stale results, retained models after telemetry failure, cancellation ownership, retirement/drain, URL/alias admission and app settings preservation. A separate actual HTTP test creates two temporary loopback servers: each receives only its selected role's pull, discovery and runtime requests; existing-server startup detection does not adopt a process. All observed requests omit Authorization. Listener/connection shutdown is awaited. The servers return inert responses, so this test downloads no weights and runs no inference.

The first development compile failure was a missing `try` on the new test's store close; it is retained. Development logs precede final early app-drain cancellation wiring and a small HTTP-fixture weak-capture/bounds adjustment; the final source is covered by the qualification above. Earlier successful model comparisons, benchmarks, reviewers, publishers and packages are not repeated or modified. All 492 preceding published benchmark/feature/landscape files remain unchanged.

## Remaining acceptance

This validates controller routing and task ownership, including actual loopback HTTP. It is not a new measurement of model quality, speed, energy or child-process startup/exit settlement. GUI clicks/TCC and older-Mac acceptance remain conditional. The earlier [model comparison](LOCAL-MODEL-COMPARISON.md) and [preset qualification](LOCAL-MODEL-PRESETS.md) keep their original scopes. All 83 feature statuses remain unchanged; complete sync, physical capture/energy, signed/notarized distribution, full v0 and competitive ranking acceptance remain open.
