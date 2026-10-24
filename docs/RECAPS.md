# Source-linked saved recaps

New recaps saved from Ask or a conversation retain ordered links to their originals, evidence revisions and optional text anchors. The native inspector identifies AI-generated text, distinguishes its save date from the originals' dates, and opens each original only after checking its revision. Ask also warns when it retrieves a saved recap. It does not expand evidence beyond the user's current search filters.

Saving checks current privacy exclusions and validates 1–60 complete source revisions inside the writer transaction. A stale, missing, incomplete or cyclic source graph fails without publishing a recap. Provider and link metadata are bounded; source bodies are not copied into provenance. Existing links cannot silently be detached or replaced by importing a plain record with the same ID. A deliberate independent copy must use a new note.

## Source changes and erasure

Deleting or revising an original removes all live recaps derived from it, including recaps of recaps. Cited conversation turns are removed as well. This includes typed speaker and visual-recording metadata changes even when their plain text is unchanged. Tags and favorites do not change evidence revisions. Removing a recap preserves its originals and unrelated branches. Removing a conversation alone preserves a separately saved recap while its originals remain.

Schema 15 stores source edges with foreign keys and transitive SQLite deletion/revision triggers. The deletion queue from schema 14 handles media cleanup; graph identity rotation and a durable dirty marker invalidate disposable search files. Scope previews count the matching originals separately from derived recaps outside the selected app/time scope. Confirming erasure removes that entire dependency closure, including favorited derived recaps. Individual deletion and retention report actual committed totals.

An open native recap checks its own revision while visible and closes a stale selected copy if another connection changes or removes it. Source cards load bounded metadata, with full originals loaded on demand. Native click/focus/accessibility acceptance remains pending while the Mac is locked; render and controller tests are separate evidence.

## Portability

- JSON export preserves ordered link metadata. Import orders parents before children, rejects incomplete graphs atomically, and reports dependent recaps omitted when an original is excluded, redacted or stale. Filtering an import does not purge records already in the receiving library.
- The native JSON importer runs off the main thread, supports cancellation, guards duplicate admission and reports exclusions/omissions. Library switches cancel workers and prevent late refresh/indexing in the old model.
- Full backup restores all records into the trusted current schema, then rebuilds and validates links. It does not trust archived triggers. Restored capture and routines remain quiet.
- Markdown export uses a disk-backed dependency pass when links exist. It suppresses recaps and cited turns whose originals are hidden or redacted, even when children precede parents physically. Allowed source links resolve to relative Markdown files. Plain libraries keep the existing streaming path.

JSON, Markdown and backup folders are independent external snapshots. Later live deletion cannot erase them. Earlier OSwind recaps saved without links remain explicitly labelled independent copies; their provenance is not guessed. This is logical live-library erasure, not secure SSD wiping.

```bash
oswindctl chat save-recap SESSION_ID --turn TURN_ID --title "Release recap"
oswindctl import complete-library.json --json
oswindctl erase preview --app Notes
```

The CLI can save a specific older turn even beyond the recent 1,000-turn window. A schema-14 library upgrades without changing its source identity; a pinned older executable refuses schema 15 without changing database bytes. That proof does not cover already-open old processes or arbitrary raw SQLite mutation.

## Validation

The [machine-readable evidence](../benchmarks/linked-recaps-v1.json) records exact source/binary pins, full and ThreadSanitizer suites, process checks, actual local Qwen answers and release/package binding. Owned fixtures exercise a 110-level chain, separate branches, precise anchors, incomplete/reversed JSON, privacy propagation, full restore, Markdown links and deletion counts. This milestone does not establish natural recap quality, whole-library wipe recovery, encrypted vault support, continuous capture power or competitor/top-three performance.
