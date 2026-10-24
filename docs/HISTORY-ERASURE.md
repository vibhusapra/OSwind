# Selective history erasure

Open Settings → Privacy or Data → **Erase by time, app or website**. Choose an optional time range, exact application name, exact bundle ID, website hostname and source type. All selected filters intersect. **Pause & preview** pauses screen/audio capture and discards unfinished replay, then shows matching sources, dependent conversation turns and media references. Review up to five recent source titles before choosing Erase.

Erasure requires an unchanged preview token bound to this library, the selectors, the source revision and affected cited turns. Any source mutation, including a concurrent capture, or a newly saved cited answer invalidates the preview. Capture remains paused after the operation. Source deletion and durable media-queue admission commit in one SQLite writer transaction; cancellation before commit rolls back. Once committed, cleanup reports its actual outcome even if cancellation arrives late.

## Matching rules

- Time is a half-open range: start inclusive, end exclusive. A source that overlaps the range is removed in its entirety. A clip ending exactly at the start is kept; an instantaneous source at the start is included. There is no partial audio/video trimming.
- App names and bundle IDs are exact, case-sensitive strings. Both can be supplied and intersect. This is separate from fuzzy text search and query syntax.
- Websites are recorded HTTP(S) URL hostnames. Case, a trailing dot and internationalized hostname encoding are normalized. Subdomains are included by default, with a checkbox or `--exact-host` to restrict to the host. `example.com.evil.test`, `notexample.com`, a username containing the domain and missing URLs do not match `example.com`.
- At least one selector is required. Notes and favorites are included if they match. Time is based on recorded timestamps, not inferred mentions inside text.

The source delete triggers remove FTS entries, speaker labels, previews, vectors/passages and entire conversation turns that cited the source; affected conversation titles reset to “Conversation”. In-flight answers using removed evidence cannot publish. Routine definitions and unrelated conversation turns remain; a routine result loses availability when its cited turn is removed.

## Retained-media cleanup

Only the selected sources' media references enter a durable SQLite queue. Cleanup scans remaining references once and uses indexed lookups; a live canonical-path reference keeps a shared file, including dot-path and case aliases on an insensitive volume. Separate hard-link entries can be unlinked independently. A writer reservation prevents a new reference appearing between its check and unlink. Paths must resolve inside the owned media folders and name regular files; traversal, symlinks and directories are refused. Missing files count as already absent. Failed removals remain queued across launches and can be retried with **Retry media cleanup**.

The operation invalidates the search identity, releases current native caches and removes disposable index files. Another process may still hold old memory or rebuild a stale disposable file; source validation prevents using it as current evidence. WAL checkpointing is best effort when readers are active. Erasure is logical deletion, **not a secure overwrite guarantee for SSDs, filesystem snapshots or external copies**.

Exports, backups, copied text and other libraries remain. Earlier manually saved recap copies have no source relationships and remain unless they match the selected filters. Adding source provenance to saved recaps is a separate remaining privacy gate. This feature does not add a remote destructive HTTP/MCP tool.

## CLI

```bash
oswindctl erase preview --from 2026-10-23T18:00:00-07:00 --to 2026-10-23T19:00:00-07:00 --app Safari
oswindctl erase preview --domain example.com --exact-host
oswindctl erase apply --domain example.com --exact-host --token TOKEN_FROM_PREVIEW
oswindctl erase retry-media
```

Repeat the same selectors for apply. Invalid selectors, empty scopes, changed history and absent/incorrect tokens fail without deleting sources. JSON output distinguishes committed source/turn counts, removed files, shared files, pending cleanup and warnings.

## Verification

```bash
swift test
swift test --sanitize=thread --filter 'HistoryErasureTests|HistoryErasureModelTests|ConversationTests'
python3 scripts/erasure-smoke.py dist/OSwind.app/Contents/MacOS/oswindctl
python3 scripts/benchmark-erasure.py dist/OSwind.app/Contents/MacOS/oswindctl --root /NEW/SYNTHETIC/FIXTURE --records 20000
```

Tests cover half-open overlap, hostname lookalikes/IDNA, selector intersection, stale previews across connections, new dependent answers, shared/missing/unsafe media, queued retry, native operation busy/error states and actual cancellation during the DELETE statement followed by a working query. Eight independent CLI writers sharing one preview produce exactly one committed erasure. Full suite and sanitizer counts are recorded in the machine-readable report. Light/dark form renders were inspected. Native clicks, focus, confirmations and accessibility remain pending while the Mac is locked.

The generated scaling trial is a single cached workload with concurrent background activity, not natural capture, power, failure durability or competitor evidence. [Machine-readable report](../benchmarks/history-erasure-v1.json) records source/binary pins, release measurements and limits. [Direct FTS maintenance](FTS-MAINTENANCE.md) now removes the older per-source identifier scan. The paired generated trial and limits are recorded separately.
