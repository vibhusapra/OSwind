# Canonical mutation capture

Schema25 adds an internal local change feed for personal sync. Capture is disabled by default. There is no public activation control, peer enrollment, background sender or automatic transfer. F059 remains TODO until the complete supported-library sync workflow is usable and verified.

## Captured state

Persistent non-TEMP triggers record changes in the same transaction as each ordinary source/graph mutation. They cover 13 canonical tables: memories; chat sessions, turns and citations; recap citations; routine definitions and run history; entities, aliases, mentions, label/project rejections; and persistent evidence pins. The complete primary key and selected columns are checked against SQLite's actual schema. Derived vectors, FTS/statistics/range caches and entity-index completion do not create source intents. Routine scheduler columns stay local; the future typed adapter must also strip activation, provider paths/credentials and execution authority from definition payloads.

A small versioned binary frame preserves SQLite null/integer/real/text/blob storage classes, raw UTF-8 including NUL, and finite Float64 bits. Row frames are bounded at 136 MiB; primary-key framing at 64 KiB. Keys in the queue are 32-byte SHA256 digests of the byte-framed complete primary key, scoped by table and local capture identity. They do not contain raw source IDs or alias names, but are not a promise of resistance to guessing known inputs. This local format is not a validated peer payload and must never be published directly.

Every committed intent retains its sequence and old/new key relationship. Only the latest pending put body for a key remains: superseded bodies are cleared, and a canonical deletion clears its previously pending body and records an opaque deletion intent. This keeps removed source/chat/recap/title/alias text out of the live queue. It does not claim forensic erasure of filesystem/provider versions, complete collection/wipe barriers, or an immutable history of every intermediate edit. The processor must assign object lifetimes before consuming superseded insert/delete metadata and preserve already-published evidence versions separately.

Four accounting triggers join 39 table triggers. The default logical queue budget is 1 GiB, with an 8 GiB upper bound; accounting includes key/body lengths and a fixed per-entry allowance. This is not a filesystem quota. Budget or SQL failure rolls back both source and intent changes. Full offline retention/compaction/backpressure behavior must be finished before this internal mode is exposed: an undrained full queue currently refuses the source mutation rather than silently dropping its intent.

## Connections, recovery and boundaries

Every MemoryStore connection registers the bounded, pure row/key functions. When capture is active, ordinary writers prepare SQLite FULL synchronization and recursive triggers, including connections opened before activation. Persistent triggers refuse unregistered or unprepared writers; schema25 also fences older supported clients on open. FULL is a requested SQLite durability mode, not physical power-loss evidence.

Startup verifies exact capture trigger definitions. Missing or changed ordinary hooks refuse instead of silently repairing an unknown gap. The established cold evidence-pin table repair is preserved as a specific exception: only that table's three missing capture hooks are recreated, before recovered references repopulate its pins. Active reopening prepares durability before this repair. Existing source extents and citation pins stay protected.

A scoped peer-apply transaction may suppress echoes. It first requires the local intent queue to be drained, so incoming peer state cannot leapfrog an unconverted local edit. Suppression and original writes roll back together on failure; no other connection sees an uncommitted suppression flag. The processor must commit validated protocol/cache output and acknowledgement in the same transaction and revalidate any content prepared outside it. The capture origin/generation identifies this local intent history; it is not delivered global source-origin/lifetime mapping.

Current backup/restore copies canonical data through the existing typed path; restored libraries stay capture-disabled with no pending intent replay. Complete sync origin/membership recovery still requires its own validated bootstrap. Public single-delete and full-wipe fixtures verify that live queued original bodies disappear; peer deletion announcements, collection/wipe epochs, encrypted-cache retention and provider-version handling remain delivery requirements.

## Development evidence and next gates

The development sequence retains a C callback compilation failure, an incorrect Date-bit fixture expectation, and a real cold-pin-repair regression. The repaired broad selection passes 218 cases with one existing worker skip. The final focused selection and sanitizer selection each define 74 cases: 72 pass and two subprocess-worker entry points skip. Both automatic-capture crash parents execute: a killed pre-commit child leaves neither source nor intent; post-commit recovery keeps both and the next sequence.

A structural fixture independently enumerates all 13 tables and exercises insert, update, primary-key changes and cascading deletion. Public operations separately cover source-linked chat/recap deletion, queued title/body removal, full wipe, active backup/quiet restore, two concurrent connections and cold pin repair. Structural raw SQL snapshots alone do not establish valid peer admission or full graph synchronization.

The scale fixture measures actual favorite transactions and default-prefix, required-phrase and broad 100-result keyword queries. Controls use the same owned library, alternating rounds and FULL/recursive mode for both profiles. An independent Python SQLite/struct/hash reader checks all original IDs/text/payloads, current snapshot bytes/key digests, sequence/accounting and raw timing quantiles. The first staged process preflight verifies an actually initialized old24 collector refuses a late write after migration, with original payloads unchanged. It then stops because the smoke restore invocation omits required --to; the script is corrected and this failed attempt is retained. An initial fixture wrongly assumed unquoted numeric search was exact; its 12 failed assertions and invalidated completion JSON remain retained. Product search is unchanged. The corrected fixture measures default prefix behavior and explicit required phrases separately, and includes broad archive queries. Development timings are not frozen qualification, cold-cache, import, GPU, desktop energy or competitor-ranking evidence.

The first frozen full run at 6908af6 defines 1,381 cases: 1,369 pass, five explicitly skip and seven fail (18 assertions, including two unexpected errors). Remaining qualification stages do not run. It exposes a retention bug: VACUUM creates a fresh WAL that was counted before its final checkpoint, causing unnecessary evidence deletion under a small budget. Compaction now checks both checkpoint results and checkpoints again after VACUUM. A held-reader regression requires zero evidence/vector loss while compaction is busy and a successful non-destructive retry after the reader releases. The original 1 MB budget assertion stays intact. The legacy migration fixture now removes hooks/state that never existed in schema five; specific archive-tamper and concurrent-writer fixtures register the real connection functions. The unregistered-writer refusal remains independently tested. The focused selection defines 140 cases: 138 pass and two subprocess-worker entry points skip. The failed frozen run and diagnostic are retained; the corrected full, sanitizer, optimized, scale and package qualification is recorded below.

An independent legacy deletion-process preflight then reproduces the same missing-function fixture setup, before any product deletion occurs. The second qualification attempt at 13ecb03 is deliberately stopped with SIGINT to its owned full-test process group; it is incomplete coverage, not a passing qualification or a new product assertion failure. Six legacy CLI fixture scripts now register function names only after checking capture is disabled and unsuppressed. Their callbacks always refuse if executed, so this helper cannot fabricate frames or become an active writer; actual product writers still use the Swift codec. Five offline helper contracts pass. Authored erasure, deletion, wipe, backup, Markdown and CPU/CoreML PII-provenance process groups all pass against the earlier staged 6097 binary, including the requested interruption controls. The corrected ordered run below repeats them against the corrected packaged source. No original failure or stopped report is overwritten.

## Frozen qualification at 793574e

[PR #94 receipt](../benchmarks/sync-change-capture-v1.json) retains all 31 passing stages over 774 unchanged inputs.

| Check | Result |
| --- | --- |
| Full suite | 1,382 defined; 1,377 pass; 5 skips; zero failures |
| Thread Sanitizer selection | 324 defined; 322 pass; 2 skips; zero failures; zero race warnings |
| Optimized selection | 324 defined; 322 pass; 2 skips; zero failures |
| New frame/capture/crash cases, each build | 27 defined; 26 pass; worker-only skip; both crash parents execute |
| Signed processes | Initialized old24 writer refusal; current collector and concurrent writers; deletion and quiet restore; normal/indexed HTTP/MCP, SDK, privacy, eight schema-sensitive smoke groups and six legacy process groups pass |
| Independent review | All current/retained input and log hashes verified; all 11 traced images absent; installed 15-file app unchanged; strict package and extracted ZIP/payload equality |

The full skips are reported explicitly in the receipt. Subprocess entry points skip outside their owned workers, and the separate scale fixture runs at every requested size. Device/session gates remain device gates. The original seven-case full failure and the deliberately stopped second attempt stay separate from these passing results. Compaction regressions, archive-tamper assertions and concurrent attribution/scope tests pass in all three builds. Hosted793 benchmark checks pass; its native job fails the project-metadata fixture setup reproduced and corrected below. At the ba0f3db follow-up snapshot, benchmark CI passes and native CI is still running. Publication-head CI is separate; no running job is counted as success.

The script-only follow-up at ba0f3db passes all eight fresh stages against the exact previously qualified signed CLI. Hosted13ec and local793 project-metadata setup failures remain retained. The seventh smoke fixture and five maintained benchmark loaders now use the same inactive-only helper; the backup-loader expectation also requires the explicit zero visual-index diagnostic, with the first follow-up failure retained; all 12 known current Python fixture writers are inventoried separately from explicit refusal controls, generated mock schemas and the historical schema13 harness. Independent review checks every current frozen input and the original793 inputs at their historical Git objects. Swift, tests, SDK, CI, models, assets and package bytes remain identical. These small loader checks are functional contracts, not new scaling measurements or a rerun of the full suite.

### Authored capture overhead and archive probes

| Sources | Favorite transaction p95, inactive / active | Prefix lookup p95, inactive / active | Required phrase p95, inactive / active | Broad 100-result p95, inactive / active |
| --- | --- | --- | --- | --- |
| 1,000 | 0.634 ms / 0.759 ms | 0.098 ms / 0.104 ms | 0.112 ms / 0.117 ms | 2.826 ms / 2.586 ms |
| 100,000 | 0.662 ms / 0.734 ms | 0.196 ms / 0.195 ms | 0.186 ms / 0.189 ms | 320.008 ms / 316.236 ms |
| 1,000,000 | 0.862 ms / 1.037 ms | 0.256 ms / 0.250 ms | 0.354 ms / 0.371 ms | 3067.176 ms / 3111.823 ms |

Each size alternates ten active/inactive rounds on the same authored library, with FULL synchronization and recursive triggers in both controls. There are 500 actual favorite mutations per profile, 50 prefix and 50 required-phrase lookups per profile, and ten broad queries per profile. Fifty current row bodies remain among 500 sequenced intents; all original IDs/text/payloads and current frame/key/accounting bytes are checked independently. Median/p95 and every raw timing are retained. Baseline population uses explicit fixture SQL, excludes embeddings and is not ingestion throughput. These are warm in-process measurements with small samples; they do not establish cold-cache behavior, real capture/GPU/energy performance, transport throughput or a competitor ranking. Broad-query observations are retained even when slow.

The Mac remains locked at the native UI inventory check. No settings change is attempted in this milestone; earlier task-created Spotlight exclusion restoration remains unverified (last independent count five, last visible count four). No final restoration is inferred from the passing code/package checks.

Before F059 can be delivered:

- Complete the typed processor for every graph/media object, durable origin/lifetime and versioned-citation mappings, initial bootstrap and cross-peer causal ordering.
- Admit outgoing data under current privacy rules; keep secrets, machine-local permissions/paths, scheduling authority and peer scan claims from becoming local authority.
- Finish deletion priority, collection/wipe epochs, acknowledgements, compaction, encrypted private cache and storage-pressure recovery.
- Add Keychain pairing/recovery, membership/revocation, native/CLI setup, status, conflict review and lifecycle cancellation.
- Qualify full/sanitizer/optimized/package/process paths, actual older-client refusal, scale, real file providers and two Macs. Preserve every failed run with its source and scope.

## Primary references

[SQLite application-defined functions](https://www.sqlite.org/appfunc.html) are registered per connection; the pure framing functions are marked deterministic and innocuous. [Function creation and flags](https://www.sqlite.org/c3ref/create_function.html) distinguish functions allowed in schema elements from direct-only functions. [Trigger semantics](https://www.sqlite.org/lang_createtrigger.html) motivate checking real columns/primary keys rather than trusting an UPDATE OF list.

## Additional direct-SQL fixture audit

The 31-stage local run at 793574e passes and independent review verifies all 774 inputs, 1,377 full passes / five skips, 322 sanitizer and 322 optimized passes / two worker skips each, authored 1k/100k/1m oracles, signed package/process paths and 11 absent native images. The installed 15-file app remains unchanged. This does not supersede hosted CI: source13ec fails its project-metadata smoke at an additional raw uncurated-project setup write, reproduced locally against the qualified 793 binary. The same inactive-only helper is now applied there and to five maintained authored benchmark loaders. An AST inventory distinguishes these current loaders from explicit unregistered-writer controls, synthetic mock databases and the pinned historical schema13 harness. No Swift, test, SDK, CI, model, asset or packaged product bytes change in this follow-up. All eight focused small-fixture process checks subsequently pass; original local/hosted failure evidence and the completed 31-stage run stay retained.

The first fixture-only follow-up at21ed passes helper, 1k-source project metadata, SQLite writes and calendar counts, then stops at the backup benchmark's obsolete whole-result equality assertion. Restore includes the existing explicit discardedVisualIndexes=0 diagnostic, while every original archive field and fingerprint matches. The benchmark now requires exact create/inspect equality and exact restore equality with that zero diagnostic added; no original identity/count/media assertion is removed. The failed report/logs and unrun later stages are retained. This is a maintained benchmark expectation correction; product bytes stay unchanged. The fresh eight-stage fixture follow-up below passes before publication.

## Later hosted CI boundary

The one-line schema-statistics assertion correction at cc6762e changes no product bytes. Its [hosted run 41160380168](https://github.com/vibhusapra/OSwind/actions/runs/41160380168) passes benchmark checks but fails the owned cancelled-lock native case with normal hdiutil exit 16. The cause is unproven. The subsequent search-change source 7e0d88a passes both hosted jobs; the [search receipt](../benchmarks/keyword-scope-scale-v1.json) retains both observations separately. A passing later run does not resolve the earlier detach failure.
