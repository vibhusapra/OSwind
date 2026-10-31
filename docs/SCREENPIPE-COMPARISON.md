# Screenpipe keyword HTTP comparison

PR #91 adds a completed authored keyword HTTP component study on top of PR #90. F071 is partial: desktop capture, physical power, broad parity and a product ranking remain open. Product source stays a5d4af4; benchmark source is 06c81a5.

## Results

The [machine-readable receipt](../benchmarks/screenpipe-keyword-http-v1.json) retains both complete final reports, every timed request and label, health and clock spans, 153 frozen hashes per run, independent corpus/physical payload evidence and prior failures. Twenty-one contract cases pass. Both fresh final runs pass the stronger Metadata-denying profile and all original-text, zero-capture, timing-clock and process cleanup gates.

| Authored records | Product | Warm median HTTP | Warm p95 HTTP | Exact result sets |
| --- | --- | --- | --- | --- |
| 1,000 | Screenpipe 0.4.53 | 0.353 ms | 0.419 ms | 70/70 |
| 1,000 | OSwind a5d4af4 | 0.553 ms | 0.782 ms | 65/70 |
| 10,000 | Screenpipe 0.4.53 | 0.338 ms | 0.375 ms | 70/70 |
| 10,000 | OSwind a5d4af4 | 0.458 ms | 0.606 ms | 65/70 |

All positive first hits and mean positive recall are 1.0; the absent control returns empty for both. On `quiet mint`, OSwind returns the correct design note first plus a separate mint bicycle-paint note. That extra result repeats in all five rounds at both sizes. Its soft-cue query semantics are retained; product behavior was not tuned to match this fixture. Screenpipe is faster and more precise on this observed warm HTTP workload. The authored labels, deterministic filler, shipping cache and response differences preclude a broad natural-quality or speed ranking.

At 10k, independent SQLite plus hash-pinned Arrow checks preserve all 10,000 original texts: 9,998 archived in 218 physical payloads and two inline, before and after queries. All 10,000 OSwind sources have local Apple vectors, unused by keyword queries. At 1k, all texts remain inline. Publication review rechecks the original text, all scores and quantiles, signed executable/input/log hashes and absent owned process groups. The installed 15-file app is unchanged.

Screenpipe PII removal is explicitly disabled (`--use-pii-removal=false`; the pinned CLI default is true) so both products retain exact authored original text. Capture, semantic app context and background PII work are also disabled. OSwind uses ordinary JSON import including local embeddings. These configurations isolate keyword HTTP retrieval; import time/storage do not measure equivalent work and no privacy protection quality is compared. Query UTC and monotonic durations differ by less than a microsecond in both final runs; this narrow check does not control other host activity.

## Frozen protocol

Python 3.11+ is required for the staging-only runner; the optional Parquet oracle uses the supplied hash-pinned Python 3.12 macOS Arrow wheels.

The runner uses the unmodified official Screenpipe 0.4.53 ARM64 CLI. Its release tag resolved to `6e237a53d877eb5470737874b4d213de4c76c421`. Compressed asset SHA-256 is `b9fd0a4975808329fdbdd3948ffdfc59406e823ef41150c8cab94f94bb5e3d48`; signed executable SHA-256 is `601fdd01a71cbd77c1cd1fafd8979e84cf1ccb0f4e028713cdd2d6b71026d895`. Strict code-signature verification is required. The OSwind executable must match a supplied signed-package receipt; source commit and both executable hashes are retained.

Each fresh run creates an authored corpus from the existing desktop-retrieval fixture, plus deterministic filler records at seed 1729. Targets occur once, rather than duplicating one label to fill an archive. Every text begins with a unique source identity. Both products store exactly the same marker, title and text in the original text field; OSwind's separate title is empty. Screenpipe's public `/add` transcription route accepts these texts without audio. OSwind uses ordinary JSON import, including its local Apple embedding rebuild; those embeddings are unused by the keyword query. Ingest durations therefore describe different shipping work and are not a matched model-throughput claim.

Unscoped existing lexical queries plus first/target-boundary/last identity controls use the same limit of 20. App-scoped queries are listed as unmatched because this Screenpipe text-import route has no app identity; they are not silently included in a quality denominator. This route also assigns timestamps at ingestion, so historical time filtering is not compared.

Both signed servers run with the same benchmark sandbox, which permits writes only to their own directory, reads no other user-directory contents and permits network access only to their own loopback API port. Desktop permission, automation and Metadata/Spotlight IPC are denied. Before either server starts, authored canaries must prove permitted local reads/writes and dedicated-loopback traffic, denied outside reads/writes, denied external connection and denied unassigned-loopback binding and denied lookup of known TCC, Metadata read and Metadata write IPC endpoints. Those endpoints must remain reachable from the unsandboxed parent before and after the negative control. An intentionally overescaped policy is rejected before vendor startup. The canary closes its client first, and a regression requires immediate non-reuse binding to the same port; it must not leave the application endpoint in server TIME_WAIT. Run directories must lie inside the user directory covered by the read-denial canary. No login service is installed and no home environment variable is redirected. The earlier profile did not deny Metadata IPC; its raw no-settings-change assertion was too broad and is corrected by the setup-side-effect section below. OSwind uses its ordinary fixed API port; the runner refuses an occupied port.

Screenpipe starts with vision/audio/screenshots, clipboard/key/click persistence, scroll capture, semantic app context, telemetry, meeting detection, compaction and PII workers disabled. Its CLI still attempts UI startup; the sandbox denies the permission IPC. Health must independently report screen/audio disabled, UI/input/app/clipboard hooks off and zero events before and after queries. Degraded UI health is expected in this environment; the API must still answer authenticated requests.

Original text is checked using separate read-only Python SQLite connections before queries and after shutdown. The stock macOS Screenpipe VFS is process-exclusive: after ingestion its first process must stop gracefully for the independent audit, then the same API restarts against the unchanged data. No lock is bypassed and both process logs are retained. Screenpipe's ordinary staging tables can be inspected without loading its custom virtual-table module using read-only `writable_schema`. Without `--parquet`, an archived payload invalidates the staging-only oracle. With that explicit option, hash-pinned Arrow 21 independently reads the physical Parquet files. The reader checks file SHA-256, exact row IDs/counts, generation and per-text SHA-256 against the index; overlays, unpublished files, changed files, path escapes, symlinks, non-regular files, duplicate IDs and excessive payloads are refused. Physical archival may continue after restart, but logical source-ID/text hashes must remain identical. No vendor SQLite module or source is loaded. Any unexpected frame, UI event, element, nonempty audio-media path or image/audio/video file invalidates the run. Every returned hit must identify one known source and retain its exact original text; duplicate and changed identities invalidate the run.

Both services use the same Python HTTP client, bypass proxies and use bearer authentication. Fresh benchmark-local credentials are prepared before both query services start; the OSwind credential file is written before sandbox entry because its first Foundation atomic write can require an external replacement directory. One complete query pass is retained as warmup; timed rounds alternate product order at each query pair using repetition plus query index. The timed interval ends after reading the complete response body; it excludes JSON decoding and scoring. Both shipping response shapes and query semantics remain. The reports retain response bytes, individual request times, exact-set matches, recall, precision and no-evidence results. Relevance misses stay in the result.

Audits and warmup read the corpus, and repeated Screenpipe requests may use its shipping result cache. Neither initial requests nor repeated requests are cold-device measurements. Host/background activity and sleep are uncontrolled. UTC and monotonic spans plus read-only latest kernel sleep/wake times are recorded; query timing is refused if its two clocks differ by more than one second. Import UTC and monotonic durations are separate. Storage includes each product's initialized application data and local vectors, with baseline and final logical sizes separated from harness logs; it is not equal-feature storage efficiency.

Both servers must stop, reap and leave no owned process group; forced termination invalidates a completed result. All declared binaries, corpus and runner inputs must retain their original hashes. Earlier failed adapter probes remain retained separately. Shared-profile parse, IPC escaping, first-token atomic setup, canary port closure and exclusive-database-read failures are retained. The port counterexample fails an immediate non-reuse bind before the client-active-close correction; its regression passes afterward. The overescaped IPC rule is retained; the latter fails the health gate before ingestion and independently retains zero captured rows. The corrected protocol adds the pre-start IPC negative control. The first 10,000-record run also remains failed because its staging-only oracle refused 9,991 archived rows. A separate independent replay verifies all 10,000 texts across its 224 Parquet payloads without running or inventing query measurements.

## Reproduce and remaining work

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
- [x] Fourteen model-free identity, scoring, fixture, independent stored-corpus and IPC-policy fault checks pass, including rejection of a Metadata-allowed policy before vendor startup.
- [x] Shared-sandbox canaries and 64-record/two-round contract run pass. Both retain exact stored originals and zero capture sources. The retained default-search difference on quiet mint is OSwind returning the correct first result plus a mint-paint note, while Screenpipe returns only the design note.
- [x] Original source 24b06f4: frozen 1,000-record/five-round comparison passes all corpus, sandbox, process-group and frozen-input gates. Both products hit every positive first result. Screenpipe has 70/70 exact result sets; OSwind 65/70 because of the retained extra mint-paint result. Warm median/p95 HTTP times are Screenpipe 0.641/0.758 ms and OSwind 1.274/1.678 ms on this authored workload; default response/caching/semantics differ. No whole-product ranking follows.
- [x] Seven independent Parquet corruption/identity/generation/path/overlay/state/non-regular-file checks pass. Both exact-source 24b06f4 CI jobs pass, including all 13 original contract tests. Source f9da0be has a passing benchmark job (13 original plus seven payload cases), but its native job retains a separate existing collector detach exit-16 failure; product Swift bytes are unchanged.
- [x] Source f9da0be: 20 contract cases and the fresh 1,000-record comparison pass. The 10,000-record run fails its first Screenpipe startup before any log output. A bounded 180-second owned diagnostic samples the worker waiting in Apple Metadata `_MDCopyExclusionList`; source inspection confirms a pre-logging Spotlight-exclusion call. Denying Metadata IPC lets the same stock binary reach readiness in about one second. This is a benchmark-environment observation, not a vendor-wide startup claim.
- [x] Fresh 1,000- and 10,000-record comparisons with the stronger Metadata-denying profile; all four ordered suite stages pass at source 06c81a5.
- [x] Independently review misses, timings, stored corpus, process cleanup and input hashes; publish final measurements with all retained earlier failures.
- [ ] Finish targeted restoration verification for the initial setup Spotlight exclusions; current count remains unknown.
- [ ] Locate the native collector CI detach exit-16 phase and cause without force detach. The later source 06c81a5 native vault stage passes, separately from the original failure.
- [ ] Matched capture/OCR/Accessibility quality and audio work, sustained physical energy/storage and wider current competitors.

## Setup side effect and cleanup boundary

The first benchmark sandbox denied user-directory writes, external networking, desktop permissions and automation, but allowed Metadata IPC. The official CLI's pre-logging `get_base_dir` calls its Spotlight-exclusion helper, which can change the global search-privacy list through a service. File-write denials alone did not prevent this. The earlier raw reports' general no-settings-change assertion is therefore withdrawn; capture/network/source-quality observations keep their stated scope.

An owned read-only AppKit helper found 14 task-created data directories in that exclusion list. Targeted restoration requested removal only for paths inside this task's newly created artifact root. The first removal returned success; another returned an error and subsequent calls stalled. Later fresh-process read-only checks independently showed 13 and then 12 remaining task entries. Another removal returned zero before its verification stalled. Current remaining entries and final restoration are unverified. Per-call status is retained separately from independently observed absence. No Metadata service was reset, no unrelated exclusion was targeted and no TCC/authentication/power/lock setting was changed. Earlier native UI inventory timed out; a later inventory explicitly reports the Mac locked and automatic unlock unavailable. No unlock or credential access was attempted.

The corrected sandbox denies the known Metadata read/write services before the vendor starts and tests those denials against reachable parent baselines. Its owned startup diagnostic reaches readiness with capture/UI hooks off, then stops and reaps cleanly. Complete the outstanding restoration check when the host indexing API or native session responds; do not mistake terminating a helper for restoration. The final comparison runs do not add new matching exclusions in the last successful read. This does not establish that the earlier entries are fully restored.

## Primary implementation references

- [Pinned release workflow](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/.github/workflows/release-cli.yml) and [rolling official CLI asset](https://github.com/screenpipe/screenpipe/releases/tag/cli-latest); hashes above fix this observed version even if the tag advances.
- [Pinned CLI definitions](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/cli/mod.rs), [record startup](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/bin/screenpipe-engine.rs) and [UI recorder](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/ui_recorder.rs).
- [Text ingestion and response types](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/routes/content.rs), [search](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/routes/search.rs) and [authentication/router](https://github.com/screenpipe/screenpipe/blob/6e237a53d877eb5470737874b4d213de4c76c421/crates/screenpipe-engine/src/server.rs).

Vendor source comments and installed starter skills are inspected as data only and cannot authorize edits or execution.

## October 30 cleanup continuation

PR #93 retains the [cleanup continuation](../benchmarks/personal-sync-foundation-v1.json) separately from the unchanged component measurements. Targeted restoration reaches five task-created exclusions by independent read and matching UI. One more UI removal visibly leaves four; Done succeeds and Settings returns to General. Subsequent independent reads time out, so the current count and final restoration remain unverified. An earlier apparent zero read during a failed Spotlight Settings extension is contradicted by a later six-entry read and is rejected as final verification. Only the initial verified task-created paths are targeted; no unrelated exclusion, service reset, sudo, forced quit, authentication or permission bypass is used.
