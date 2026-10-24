# Indexed tags and responsive library opening

Tag-scoped calendar counts now read a compact metadata index instead of parsing source payloads. Combined app/type/saved counts use a covering index too. The shared search/count predicates use indexed tag membership; keyword ranking and tag spelling stay unchanged.

Tags are exact, case-sensitive stored strings. Duplicate tags in one source count once; strings with different Unicode encodings are not normalized by SQLite. The index does not infer labels, rewrite source tags or apply relevance thresholds. Speaker labels retain their separate recording-local semantics.

## Consistency and compatibility

`memory_tags` is disposable derived metadata: source ID, tag, timestamp, app, kind and saved flag. SQL insert/update/delete triggers maintain it in the same transaction as the source, including writes from the actual earlier schema20 CLI. A covering tag/time index serves calendar ranges; combined metadata scopes use a covering source index. Tagged calendar queries do not read the source table, text, embeddings or retained media. The ordinary schema remains20.

Opening an older library installs the table and indexes, backfills tags and publishes a readiness marker atomically. Cancellation rolls installation back. Missing readiness, a missing table or unexpected trigger definitions cause repair from authoritative source payloads. A current installation performs no tag-data rewrite at reopen. This is not a general corruption detector for arbitrary manual edits to derived rows. Restore deliberately ignores archived derived tags and rebuilds them from original sources. Source deletion, retention and full wipe remove their tag rows; copied backups/exports remain independent files.

Installation costs disk space and first-open time. That work is measured separately from ready-library query latency in the [evidence](../benchmarks/indexed-tags-v1.json). The million-source database grows by 172.4 MB (about 3%) for the added metadata and covering indexes. A first development trial spent 18 seconds installing on one million sources; the final version bulk-builds the secondary index after backfill. The final million-source first open still takes 18.74 seconds; bulk index construction did not resolve that cost. All earlier samples remain retained. A separate owned SIGKILL trial interrupted the installation after WAL growth: recovery exposed no partial projection, retry completed, source payload hashes stayed identical, and the complete projection matched a SQL/JSON oracle. That hashed/warm-cache retry took 5.56 seconds. Ready-library tag aggregation median/p95 is 2.67/2.76 ms, combined app/type/saved is 4.74/4.90 ms, and combined tags is 1.63/1.69 ms. First-open work is reported separately; these are seven-process observations with uncontrolled caches.

Measured SQLite write tradeoffs (three trials of 1,000 source operations): tagged 1 KiB inserts rose from 76.84 to 87.53 ms median; favorite/payload updates 9.02→29.66 ms; tag/payload updates 8.75→18.48 ms. Tagged 64 KiB insert medians 956→1016 ms and tag/payload updates 413→562 ms. These are component costs, excluding JSON encoding and application/capture/model work. Faster reads add write amplification; no end-to-end throughput win is claimed.

## Opening and stopping

The native session prepares SQLite on a utility worker. The window stays responsive, shows **Preparing local search**, and offers **Stop**. It publishes the workspace only after preparation succeeds and the selected directory still matches. A failed or late cancelled result closes its store without starting services. Retrying an explicit opening is quiet. A failed initial opening also retains permission to create a new database when none exists; retry does not incorrectly require an existing one.

Termination waits for preparation cleanup. Vault lock during preparation closes the returned connection and verifies backing-device detach before reporting locked. Recovering an original library after a cancelled copy stays quiet. A retained directory lets close release the original handles if its pathname moved; it does not create lease files in a replacement folder. Capture and cleanup continue to reject the replacement directory.

Stopping is cooperative, not an immediate process kill. Existing source history is preserved. Other writers can wait or encounter the existing SQLite busy timeout during the installation transaction. First-open work is not yet scheduled as a background migration while an old workspace keeps capturing.

## Reproduce and review

```bash
python3 scripts/tag-index-smoke.py /absolute/path/oswindctl \
  --root /new/owned/tag-fixture --old-cli /pinned/schema20/oswindctl
python3 scripts/benchmark-activity.py /absolute/path/oswindctl \
  --root /new/owned/calendar-fixture --sources 1000000 --repetitions 7
python3 scripts/benchmark-sqlite-writes.py /absolute/path/oswindctl \
  --root /new/owned/write-fixture --records 1000 --repetitions 3
```

All fixtures are synthetic and require new owned roots. The calendar harness checks every day/hour count against a Python zoneinfo oracle and includes combined and missing-tag scopes. The write harness measures SQLite triggers/indexes at exact 1 KiB and 64 KiB text sizes; JSON encoding, application admission, capture and inference are excluded. These component results do not establish ingestion throughput, energy savings or a competitor ranking. Cache state and background activity are uncontrolled; seven query samples and three write trials are weak tail estimates.

Deterministic tests cover late-success cancellation, main-actor responsiveness, termination, directory replacement, quiet retry, exact tag matching, rollback, concurrent writers, source replacement, schema20 upgrade and archive-cache rejection. Owned encrypted-volume tests cover preparation/lock/close/reopen. Component renders below are layout evidence; physical Stop/keyboard/VoiceOver interaction and broader native acceptance remain open.

![Library preparation in dark mode](../assets/library-opening-dark.png)

![Library preparation in light mode](../assets/library-opening-light.png)
