# Reliability evidence and long-run component tests

Broad 24-hour capture, power, device and fault recovery remain unproved. A synthetic component run does not establish those product gates.

## Persistent MCP/storage soak

```bash
python3 scripts/reliability-soak.py /Applications/OSwind.app/Contents/MacOS/oswindctl \
  --root /absolute/path/to/a/new/soak-run \
  --seconds 86400 --interval 20 --max-notes 200 \
  --chat-model qwen3:4b-instruct-2507-q4_K_M --chat-every 600
```

Omit `--chat-model` for a model-free run. The optional model must already be installed in a running local Ollama server; this script never starts/replaces a daemon, downloads weights, uses cloud inference or reads API keys. Apple embeddings are indexed before the answer trial. All content consists of authored token transcripts and fictional ownership notes.

The harness refuses an existing run directory, copies the selected CLI into a read-only run-owned `runner/oswindctl`, verifies its hash, and uses an explicit new library. Updating the installed app later cannot change that trial's executable. It never opens the normal capture library, grants permissions, runs screen/audio devices or listens on HTTP port 47831.

One MCP process persists throughout the trial. Separate CLI writers insert a fresh event marker while the MCP reader checks counts; subsequent reads verify visibility. The bounded note window exercises source/FTS erasure across connections. Timed previews retain exactly the expected raw text, and complete reads verify all 1,000 source segments and timestamps. Optional answers check the authored owner string and that every citation points to this run's fictional notes. Those transparent checks are not semantic accuracy or natural-meeting evaluation. Informational bounded-excerpt warnings remain in samples; all other answer warnings fail the run.

`writer_live_read_cycles` confirms the writer process was alive across a read. It does not prove that each read overlapped the SQLite write critical section. Separate transaction/concurrency regression tests cover specific lock and revision races.

## Read the evidence

- `status.json` is atomically replaced with current state, controller/MCP PIDs, hashes, counts and last sample.
- `samples.jsonl` retains every cycle, sampled MCP RSS/lifetime CPU, archive size and optional model response.
- `mcp-stderr.log` retains diagnostics; the fixture/library are preserved for inspection.
- `passed` means the requested wall duration completed without errors or oversized gaps for this component workload.
- `completed_with_gaps` cannot be called uninterrupted coverage. A gap can reflect sleep, a clock adjustment or slow work; the harness does not infer its cause.
- `failed` and `interrupted` preserve their evidence. A response deadline does not infer process exit or trigger a restart. Controlled shutdown closes the owned process; SIGTERM is recorded as interruption.

No sleep prevention or global power settings are applied. A Mac that sleeps can therefore produce an honestly incomplete run. Before relying on a saved `running` state, check the recorded processes are actually live and that samples are fresh. If a process was killed without cleanup, retain that interrupted trial; do not silently reuse its directory or count it as passed.

RSS/lifetime CPU sampling covers the persistent MCP process only. It excludes CLI writers and model daemons, can miss between-sample peaks, and is not an energy or whole-system memory measurement. Repeated synthetic notes do not represent a natural desktop archive. This run does not exercise live capture, playback/UI, permission revocation, sleep/wake capture correctness, real microphone changes, full disk, encrypted recovery or another product.

## Short regression checks

```bash
python3 scripts/test-reliability-soak.py dist/OSwind.app/Contents/MacOS/oswindctl
```

Eight cases cover actual pinned CLI/MCP write/read/erase/shutdown, preserved existing roots, recorded preparation/pinning errors, bad-initialization cleanup, a timeout with a confirmed-live unchanged PID, simulated clock gaps, and controlled termination. CI runs these without model downloads. A separate short real local-model rehearsal validates the optional answer path. Neither proves a 24-hour result.
