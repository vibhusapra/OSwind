# Soak cleanup survives unavailable diagnostics

Controller source `575205fce4199cfe76fe569570fd2bd46bc4a189` separates owned-process cleanup from filesystem diagnostics. A failed stop-file write previously skipped the worker wait/termination path; an error writing the fixture's exit record could mask the failure again. The controller now always attempts both directly returned `Popen` handles, reaps them before returning, and escalates from a graceful stop request to termination and then kill when needed. It never signals PID-file values, unrelated processes or process groups.

Launch-through-cleanup is guarded, including output failure immediately after fixture launch and failure publishing the worker handle. Diagnostic writes and fixture-log closure cannot skip child cleanup. Original operation failures remain failures; unavailable cleanup diagnostics prevent a successful completion record. A completed record is published only after both owned handles are reaped. Missing native coverage remains a refusal. The run manifest also pins the imported process-owner helper. New runs use manifest v2 and nested worker/fixture cleanup receipts; old v1 evidence keeps its original layout.

## Retained long-run failure

The original requested 86,400-second trial is **stopped and incomplete**. Its controller raises ENOSPC while writing heartbeat, stop and fixture-exit records. Session 8761 returned exit 1; exact controller, worker and fixture PIDs were absent at the terminal assessment. Worker/fixture exit codes were not persisted, so their original shutdown sequence is unproved.

The last stale `running` status reports **27,657.44 uptime seconds**, **1,380 attempts**, **three saved sources**, **1,377 lock deferrals** and **zero recorded capture errors**. These are partial observations, not 24-hour completion or uninterrupted capture. All 13,289 retained resource rows and 1,380 attempt rows parse as JSON. Original records, logs, runner, frozen worker and database remain unchanged. This patch does not restart the old trial or reclassify it as a pass.

A fresh long run needs sufficient disk headroom, existing appropriate access, independently verified process ownership and its own declared inputs/results. The earlier successful 65-second native pilot remains separate and unchanged. Manual targeted requests do not qualify automatic foreground/idle/thermal scheduling; process CPU/RSS do not measure app-attributed energy or battery life.

## Verification

Seventeen source-bound contracts pass with **real directly owned Python child processes**, inert authored fixture/XCTest payloads and mocked native signing/host/ps commands. No actual capture, TCC, user history, models, native XCTest or full filesystem is exercised by these contracts.

The checks cover simultaneous ENOSPC in heartbeat/stop/error/exit writes; resource append, log-close, output, handle and worker-launch failures; final-record failure; a child ignoring termination; interrupted final waiting; graceful file-based shutdown; cleanup faults affecting one child; completed-child exit preservation; an unrelated live sentinel; provenance refusal; and completion/refusal records after reaping. `waitpid`/process-absence assertions verify actual child joining. CI runs this selection in the offline benchmark-harness job.

Python syntax and all 17 contracts pass; five altered unittest logs are rejected. All **711 preceding non-workflow runtime inputs** and **499 preceding benchmark files** remain byte-identical. No Swift/application rebuild or successful prior runtime/benchmark/soak was repeated for this Python-only fix. The first qualification wrapper failed before tests on a path/string mismatch; its exact source/log remain retained, and the corrected wrapper succeeds.

The evidence review checks source hashes, exact unittest identities/outcomes, original failure records and CI selection. It is a Codex source/log review, without a separate external PID trace or independent human audit. A new 24-hour result, native pixel/crop checks, sustained power, full sync and production signing remain open. All 83 feature statuses remain unchanged.

[Receipt](../benchmarks/soak-controller-recovery-v1.json) · [Inputs](../benchmarks/soak-controller-recovery-inputs-v1.json) · [Raw source/log/failure evidence](../benchmarks/soak-controller-recovery-raw-v1.zip).
