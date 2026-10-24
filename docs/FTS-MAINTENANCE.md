# Direct full-text maintenance

Source updates and deletes previously found an FTS row by its unindexed string ID. That meant scanning the FTS virtual table once for every deleted source. The 20k-source selective-erasure workload exposed this cost.

A separate `memory_fts_keys` table now maps source IDs to explicit integer primary keys. Insert/update triggers address the FTS row directly; a before-delete trigger removes it while the mapping still exists, and foreign-key cascade removes the map entry. Source IDs, source payloads, semantic identity/revisions and native vector keys remain unchanged.

Implicit source-table rowids are deliberately not used as persistent keys: SQLite [allows VACUUM to change them](https://www.sqlite.org/lang_vacuum.html). Explicit integer keys avoid that dependency. A regression deliberately renumbers the source rowids and runs VACUUM before updating/deleting/searching again.

Opening a legacy cache rebuilds its FTS data inside the store's existing opening writer transaction. A cache marker and exact maintenance-trigger checks avoid repeated rebuilds; unexpected legacy triggers trigger repair. This is additive cache metadata, with schema still 13. An actual pinned prior installed build (`8fdb32c`) seeded a library, then successfully inserted, upserted and deleted against the migrated cache. This does not assert compatibility with arbitrary future writers.

The [public report](../benchmarks/fts-maintenance-v1.json) records source/binary hashes, compatibility evidence and every retained timing trial:

| Generated release workload | Earlier cache | Direct-key trial 1 | Direct-key trial 2 |
| --- | ---: | ---: | ---: |
| Erase 10k sources; preserve 10k shared files | 17.43 s | 2.89 s | 2.82 s |
| Erase remaining 10k; unlink 10k files | 8.77 s | 4.09 s | 4.35 s |

These are single synthetic cached trials with concurrent background activity, not percentiles, an isolated causal experiment, energy measurements or competitor evidence. Current CLI peak memory remains about 31 MiB. The second trial independently verifies every surviving source ID, media filename and shared-file byte string outside the timed CLI operations; the original baseline checked bulk counts plus small byte-identity process contracts.

Verification: **410 tests, 404 pass / six opt-in skips**; **37 focused ThreadSanitizer pass**. Legacy cache migration, normal CRUD, quoted search, no-repeat installation, rowid/compaction independence and all earlier migration tests pass. Signed build/package/installed/ZIP binding, actual old-writer compatibility, installed erasure/eight-writer contracts, full backup/restore/interruption and CLI/HTTP/MCP/Ask search regressions pass. All aggregate Apple/local-Qwen quality metrics on the 32-document/35-query authored fixture remain unchanged, including its known absent-evidence weakness.

```bash
swift test
swift test --sanitize=thread --filter 'FullTextIdentityTests|HistoryErasureTests|HistoryErasureModelTests|ConversationTests'
python3 scripts/fts-compatibility-smoke.py NEW_OSWINDCTL PINNED_LEGACY_OSWINDCTL --output /PATH/report.json
python3 scripts/benchmark-erasure.py NEW_OSWINDCTL --root /NEW/SYNTHETIC/FIXTURE --records 20000
```

Large legacy-library migration latency/distribution, native clicks, saved-recap provenance, unified shared-media safety for individual delete/retention, encrypted vaults, natural capture/power and competitor acceptance remain separate gates. This change does not establish overall v0 completeness or a top-three ranking.
