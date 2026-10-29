# Import preparation and publication

JSON, explicit text collectors and saved Limitless API responses now sanitize text and generate Apple source/passage embeddings before reserving the SQLite writer. The store mutex is released during that preparation, so other reads and unrelated writes can proceed. The final batch remains atomic.

This changes normal import infrastructure. Learned PII models remain manual inspection tools: they are not enabled for capture, imports or egress by this change. It does not establish desktop throughput, energy, capture completeness or competitor superiority.

## Record consistency

1. Reserve shared library activity before taking SQL locks. Close, full wipe and other supported exclusive operations wait for preparation to end.
2. Take one short read transaction containing each input ID and every directly referenced recap source. Retain hashes of the original stored payloads, including favorites, tags and typed evidence; retain absence for missing targets.
3. Release SQL, then apply prospective exclusions, text/typed-evidence sanitization, media-path stripping, collector curation and source/passage embeddings. A short metadata query reuses already-current passage indexes, preserving the existing retry fast path. No SQL lock spans embedding inference. Resolve incoming recaps in topological order against the already sanitized incoming parents or snapshotted external parents. Excluded/redacted/stale incoming evidence retains the previous omission behavior.
4. Reserve the writer and compare current stored payloads/absence with the snapshots. Any changed target or linked parent refuses the whole batch with a retry message. Unrelated writes do not invalidate preparation. These are payload-content checks, not a persisted monotonic record generation: an unsupported writer restoring precisely identical payload bytes is not distinguished.
5. Insert prepared records, projections, recap links and passage vectors in one transaction, checking cancellation. Recheck any reused passage index after insertion; if it disappeared, refuse the batch for retry rather than recomputing inference while holding the writer. An index completed concurrently is reused instead of overwritten. Verify library identity and the configured saved-policy snapshot before committing. Rollback also restores derived recap invalidation when a late settings change refuses publication.

The original source d3f0181 reservation covered record snapshot/preparation after input/decode. [The input/lifetime follow-up](IMPORT-INPUT-LIFETIME.md) now reserves before file/stdin reading and decoding, uses bounded descriptor-based regular-file reads, and joins JSON/Limitless GUI workers before close/detach/quit. Its final activity state mutex precedes SQL, matching audio/visual writers. Other workers retain separate lifecycle gates.

Import preparation is still synchronous and bounded by existing input limits. Cancellation joins the synchronous current operation; it does not interrupt Apple inference inside one embedding call. The short read snapshot and final transaction still do work proportional to target payloads and admitted rows. There is no claimed constant-time transaction or general measured latency improvement.

## Saved policy

Configured GUI and CLI imports use `LibrarySettingsSnapshot.capture(root:)` and choose `snapshot.settings.privacy` together. Malformed existing settings refuse; a genuinely missing file uses defaults. The GUI also refuses when its current in-memory privacy policy differs from the saved policy.

The snapshot retains the original settings descriptor and library directory. Current `AppSettings.save` writers atomically replace a private file under the same descriptor-bound `.settings-admission.lock`. The final check takes a shared lock through SQL commit, comparing file identity, metadata and exact bytes. Identical atomic resaves and policy change/restore invalidate the operation because the original inode remains pinned. All settings changes conservatively invalidate a configured import, including unrelated preference changes.

No settings lock spans preparation, model work or an await. Lock admission is cancellable and bounded to one second; a settings save that cannot acquire it returns an explicit busy error. Save code does not acquire SQLite while holding this lock. The order for publication is library activity, SQL, snapshot mutex, settings file lock.

Files must be owned private regular files with one link, at most 4 MiB. Symlinks, hardlinks, directories, FIFOs and invalid lock files refuse. Atomic-save temporary files are private and descriptor-relative. The snapshot's explicit `release()` is idempotent and drops its descriptors; configured routes release on success and error. Callers must release operation-scoped snapshots before detaching an encrypted volume, even when retaining the snapshot object.

```swift
let snapshot = try LibrarySettingsSnapshot.capture(root: store.root)
defer { snapshot.release() }
let result = try store.importJSONDetailed(
    data: data,
    policy: snapshot.settings.privacy,
    settingsSnapshot: snapshot
)
```

Explicit core per-request `policy:` calls remain supported without a saved-settings snapshot. They apply the supplied immutable policy and record/library fences; they do not promise to follow a changing disk policy. Manual/older same-user settings writers do not participate in the cooperative publication lock. File identity/byte checks detect many such edits, but this is not a malicious same-user filesystem boundary or an all-path learned-admission guarantee.

## Validation

Product source: `d3f018176bcf6f31a24400afd1c512a01c9cd275`, [draft PR #82](https://github.com/vibhusapra/OSwind/pull/82). [Frozen qualification receipt](../benchmarks/import-preparation-v1.json): **1,145 defined / 1,143 passes / two skips**, **88 selected TSan passes**, **88 optimized passes**, and **all 11 ordered operations pass**. The full suite uses existing pinned model/native opt-ins. The remaining skips are explicit physical system audio and unavailable visual admission; precompiled internals are outside TSan coverage. All seven packaged process groups pass, including eight settings/import race checks, encrypted collector/Limitless portability, recap, pattern, Markdown and domain filtering. The 34-file app and ZIP pass strict signatures, signature-normalized same-build payload checks and exact extracted-tree comparison. The installed app matches its previously recorded bytes. No installation or unscoped GUI launch occurred.

Earlier source `b1449f7` passed ordinary/native/selected TSan/optimized tests and six process groups, but its recap process refused a manually written 0644 settings fixture. That fixture now explicitly uses the production 0600 contract. An additional old-source retry regression failed one assertion: a second identical import replaced all five passage keys/revisions. The follow-up restores current-index reuse and adds cache-loss/refusal/retry coverage. Both earlier failures are retained; they are not passing final-source evidence.

`ImportPreparationTests` exercises actual same/other-connection progress while preparation is gated, target edits, favorite/tag curation, concurrent insertion/deletion, external recap parent changes, cancellation, settings changes/resave/ABA, recap rollback, exclusive activity admission, root replacement and Apple passage persistence. `LibrarySettingsSnapshotTests` covers strict decoding, file types/bounds/privacy, wrong root/policy, release, mutation and shared-lock publication. GUI tests cover ordinary imports, malformed disk settings and mismatched in-memory policy. The opt-in native test releases a retained settings snapshot before verified encrypted detach/reopen.

The independent `scripts/import-preparation-smoke.py` runs the packaged CLI in a new owned library. It observes the collector's actual retained settings descriptor using `lsof` while stdin is held open, then tests changed settings, identical resave, policy ABA and unchanged admission. It also tests malformed-policy refusal in all three configured CLI routes and successful repair/retry. The CLI binary is hash-checked throughout. CI runs this process contract after packaging.

The initial publication parser refused because one passing case was adjacent to an interleaved owned-vault trace rather than a line start. Complete-case parsing now reconciles unique cases against the terminal XCTest total; the original logs are unchanged. The first refusal remains recorded.

These controlled checks establish publication/concurrency contracts, not an isolated desktop performance benchmark. Physical capture/power, broader learned policy and media treatment, sync/distribution, matched full competitors and the unresolved independent visual-vault CI detach failure remain release gates. Feature statuses are unchanged.
