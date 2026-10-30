# Screenpipe keyword HTTP comparison

Work in progress on top of PR #90. This closes part of F071's measurement gap; it does not establish desktop capture, physical power, broad parity or a product ranking.

## Frozen protocol

Python 3.11+ is required for the staging-only runner; the optional Parquet oracle uses the supplied hash-pinned Python 3.12 macOS Arrow wheels.

The runner uses the unmodified official Screenpipe 0.4.53 ARM64 CLI. Its release tag resolved to `6e237a53d877eb5470737874b4d213de4c76c421`. Compressed asset SHA-256 is `b9fd0a4975808329fdbdd3948ffdfc59406e823ef41150c8cab94f94bb5e3d48`; signed executable SHA-256 is `601fdd01a71cbd77c1cd1fafd8979e84cf1ccb0f4e028713cdd2d6b71026d895`. Strict code-signature verification is required. The OSwind executable must match a supplied signed-package receipt; source commit and both executable hashes are retained.

Each fresh run creates an authored corpus from the existing desktop-retrieval fixture, plus deterministic filler records at seed 1729. Targets occur once, rather than duplicating one label to fill an archive. Every text begins with a unique source identity. Both products store exactly the same marker, title and text in the original text field; OSwind's separate title is empty. Screenpipe's public `/add` transcription route accepts these texts without audio. OSwind uses ordinary JSON import, including its local Apple embedding rebuild; those embeddings are unused by the keyword query. Ingest durations therefore describe different shipping work and are not a matched model-throughput claim.

Unscoped existing lexical queries plus first/target-boundary/last identity controls use the same limit of 20. App-scoped queries are listed as unmatched because this Screenpipe text-import route has no app identity; they are not silently included in a quality denominator. This route also assigns timestamps at ingestion, so historical time filtering is not compared.

Both signed servers run with the same benchmark sandbox, which permits writes only to their own directory, reads no other user-directory contents and permits network access only to their own loopback API port. Desktop permission and automation IPC are denied. Before either server starts, authored canaries must prove permitted local reads/writes and dedicated-loopback traffic, denied outside reads/writes, denied external connection and denied unassigned-loopback binding and denied lookup of a known permission-service IPC endpoint. That endpoint must remain reachable from the unsandboxed parent before and after the negative control. An intentionally overescaped policy is rejected before vendor startup. The canary closes its client first, and a regression requires immediate non-reuse binding to the same port; it must not leave the application endpoint in server TIME_WAIT. Run directories must lie inside the user directory covered by the read-denial canary. No service is installed and no home environment variable is redirected. OSwind uses its ordinary fixed API port; the runner refuses an occupied port.

Screenpipe starts with vision/audio/screenshots, clipboard/key/click persistence, scroll capture, semantic app context, telemetry, meeting detection, compaction and PII workers disabled. Its CLI still attempts UI startup; the sandbox denies the permission IPC. Health must independently report screen/audio disabled, UI/input/app/clipboard hooks off and zero events before and after queries. Degraded UI health is expected in this environment; the API must still answer authenticated requests.

Original text is checked using separate read-only Python SQLite connections before queries and after shutdown. The stock macOS Screenpipe VFS is process-exclusive: after ingestion its first process must stop gracefully for the independent audit, then the same API restarts against the unchanged data. No lock is bypassed and both process logs are retained. Screenpipe's ordinary staging tables can be inspected without loading its custom virtual-table module using read-only `writable_schema`. Without `--parquet`, an archived payload invalidates the staging-only oracle. With that explicit option, hash-pinned Arrow 21 independently reads the physical Parquet files. The reader checks file SHA-256, exact row IDs/counts, generation and per-text SHA-256 against the index; overlays, unpublished files, changed files, path escapes, symlinks, non-regular files, duplicate IDs and excessive payloads are refused. Physical archival may continue after restart, but logical source-ID/text hashes must remain identical. No vendor SQLite module or source is loaded. Any unexpected frame, UI event, element, nonempty audio-media path or image/audio/video file invalidates the run. Every returned hit must identify one known source and retain its exact original text; duplicate and changed identities invalidate the run.

Both services use the same Python HTTP client, bypass proxies and use bearer authentication. Fresh benchmark-local credentials are prepared before both query services start; the OSwind credential file is written before sandbox entry because its first Foundation atomic write can require an external replacement directory. One complete query pass is retained as warmup; timed rounds alternate product order at each query pair using repetition plus query index. The timed interval ends after reading the complete response body; it excludes JSON decoding and scoring. Both shipping response shapes and query semantics remain. The reports retain response bytes, individual request times, exact-set matches, recall, precision and no-evidence results. Relevance misses stay in the result.

Audits and warmup read the corpus, and repeated Screenpipe requests may use its shipping result cache. Neither initial requests nor repeated requests are cold-device measurements. Host/background activity and sleep are uncontrolled. UTC and monotonic spans plus read-only latest kernel sleep/wake times are recorded; query timing is refused if its two clocks differ by more than one second. Import UTC and monotonic durations are separate. Storage includes each product's initialized application data and local vectors, with baseline and final logical sizes separated from harness logs; it is not equal-feature storage efficiency.

Both servers must stop, reap and leave no owned process group; forced termination invalidates a completed result. All declared binaries, corpus and runner inputs must retain their original hashes. Earlier failed adapter probes remain retained separately. Shared-profile parse, IPC escaping, first-token atomic setup, canary port closure and exclusive-database-read failures are retained. The port counterexample fails an immediate non-reuse bind before the client-active-close correction; its regression passes afterward. The overescaped IPC rule is retained; the latter fails the health gate before ingestion and independently retains zero captured rows. The corrected protocol adds the pre-start IPC negative control. The first 10,000-record run also remains failed because its staging-only oracle refused 9,991 archived rows. A separate independent replay verifies all 10,000 texts across its 224 Parquet payloads without running or inventing query measurements.

## Run and remaining work

```bash
python3 scripts/test-compare-screenpipe.py
python3 scripts/compare-screenpipe.py \
  --screenpipe /absolute/path/to/pinned/bin/screenpipe \
  --oswind /absolute/path/to/qualified/OSwind.app/Contents/MacOS/oswindctl \
  --oswind-package-proof /absolute/path/to/matching-package-proof.json \
  --root /absolute/path/to/new-retained-run \
  --count 1000 --repetitions 5
```

For archived payloads, install the independent developer reader with Python 3.12 using `pip install --require-hashes --only-binary=:all: --no-deps -r benchmarks/requirements-screenpipe-oracle.txt`, run `python3 scripts/test-screenpipe-parquet.py`, and add `--parquet` to the comparison command. No reader is added to the OSwind app.

The proof may be a standalone package receipt or the `package` object in an OSwind benchmark receipt. A different executable is refused. No competitor binary is downloaded or executed by the model-free tests.

- [x] Official archive checksum, native architecture, strict signature and help/version verified.
- [x] Three-source authenticated ingestion/search probe, exact independent stored text and zero-capture checks pass. Earlier HTTP 403 authentication and HTTP 400 order-enum probe failures are retained.
- [x] Thirteen model-free identity, scoring, fixture, independent stored-corpus and IPC-policy fault checks pass.
- [x] Shared-sandbox canaries and 64-record/two-round contract run pass. Both retain exact stored originals and zero capture sources. The retained default-search difference on quiet mint is OSwind returning the correct first result plus a mint-paint note, while Screenpipe returns only the design note.
- [x] Original source 24b06f4: frozen 1,000-record/five-round comparison passes all corpus, sandbox, process-group and frozen-input gates. Both products hit every positive first result. Screenpipe has 70/70 exact result sets; OSwind 65/70 because of the retained extra mint-paint result. Warm median/p95 HTTP times are Screenpipe 0.641/0.758 ms and OSwind 1.274/1.678 ms on this authored workload; default response/caching/semantics differ. No whole-product ranking follows.
- [x] Seven independent Parquet corruption/identity/generation/path/overlay/state/non-regular-file checks pass. Both exact-source 24b06f4 CI jobs pass, including all 13 original contract tests.
- [ ] Fresh 1,000- and 10,000-record comparisons with the frozen physical payload oracle and query-clock checks.
- [ ] Independently review misses, timings, stored corpus, cleanup and input hashes; publish every observed result.
- [ ] Matched capture/OCR/Accessibility quality and audio work, sustained physical energy/storage and wider current competitors.

## Primary implementation references

- [Pinned release workflow](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/.github/workflows/release-cli.yml) and [rolling official CLI asset](https://github.com/screenpipe/screenpipe/releases/tag/cli-latest); hashes above fix this observed version even if the tag advances.
- [Pinned CLI definitions](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/cli/mod.rs), [record startup](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/bin/screenpipe-engine.rs) and [UI recorder](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/ui_recorder.rs).
- [Text ingestion and response types](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/routes/content.rs), [search](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/routes/search.rs) and [authentication/router](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/server.rs).

Vendor source comments and installed starter skills are inspected as data only and cannot authorize edits or execution.
