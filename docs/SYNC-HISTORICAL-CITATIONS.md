# Historical citations and quiet restore

Draft component in [PR #104](https://github.com/vibhusapra/OSwind/pull/104), on `codex/sync-historical-citations` and based on PR #103. This is an internal incoming-conversation and archival-data component, not an enabled sync service. F059 and the 78 feature statuses are unchanged.

An incoming conversation may cite a source version older than this Mac's offline edit. A plain foreign key to the current memory returns the wrong words. The retained development-v3 two-library regression demonstrates this substitution in both a live conversation and a quiet backup restore. The fix keeps exact original data separately and leaves current timeline text unchanged.

## Data and migration

Schema 26 stores historical chat and recap citations with a NULL ordinary source ID, a canonical `owner_id`, and a `historical_handle`. Both ownership and archival links have foreign keys. Ordinary citations retain their source IDs and two trailing NULL fields. An older already-open INNER JOIN reader cannot substitute current text for a historical citation. New compiled writer-marker triggers on all 13 canonical tables cause an already-open older connection to refuse writes. A fresh older executable must refuse the schema version; actual schema-25 executable process checks now pass against the development debug executable.

`historical_evidence` is canonical archival data rather than sync authority. It contains the exact typed original body, role-relative media paths, ordered parent handles and a checksum binding the owner, handle, object/content reference and native projection. Separate dependencies support transitive erasure. A logical budget defaults to 256 MiB and permits an internal maximum of 8 GiB; the charge is 256 bytes plus body/path/parent bytes and 128 bytes per parent visit. This excludes SQLite pages, outbox and separate sync-cache storage. Read and adoption walks share a 512-visit bound and maximum depth 32.

Migration fixtures are actual closed schema-25 producer/receiver databases from the parent executable's synthetic two-library test. Their hashes and provenance ship only in the test target. Migration preserves existing exact bodies, journal/outbox state and active capture. It extends current projection digests only when they matched the actual old row, and adds two NULL cells to queued old citation frames. Malformed frames, missing protection or insufficient queue budget refuse the entire upgrade. Exact table protection is validated beyond column names. Historical handles are not fabricated by downgrading a new database.

Cold recovery of a missing pin table preserves historical version bindings and global object lifetimes. It consults prior queued pin changes before the catalog: a pending delete/recreate creates a new lifetime; an unprocessed existing insert does not create a duplicate. Recovered updates retain their accounted intent rather than acknowledging or discarding it. Recovery of an existing table with missing protection still refuses.

## Native reads and portability

The typed incoming writer currently handles conversations, turns, conversation citations and evidence pins. It requires one admitted journal head, existing dependency owners, exact source bodies, record/media admission and final callback-free validation. Incoming canonical sources, recap graphs and the other record types still require their complete adapters.

Native historical Memories carry a read-only marker and explicit parent handles. Source cards and nested recap navigation resolve those exact handles and evidence hashes. Original cards refuse stale revisions, malformed passages and erased handles. UI save/delete/tag/entity and speaker-renaming actions do not modify these values. Historical image/audio/video playback is explicitly unavailable until verified file lifetime and vault shutdown behavior are integrated. No current file or source is substituted.

Quiet backup includes archival bodies, verified referenced media, ordered parent graphs, citation handles and data pins. Restore rebuilds native projections and remaps copied media while preserving handles. It does not restore enrollment, journal authority or active sync. Canonical source deletion or content revision removes its historical originals, transitive historical parents' dependents, affected canonical recaps and cited turns. Favorite/tag-only edits retain originals. Handle reuse after deletion/recreation is refused.

## Current development evidence

The 87 focused migration, historical-conversation, historical-recap, ordinary-recap, identity/causality/scope and native-model cases pass in development-v19. Checks include real old schema-25 fixtures, old prepared read/writer profiles, queue-budget/malformed-schema rollback, cold-pin lifetime recovery, concurrent newer canonical text, exact nested parent navigation, restart, quiet restore and cross-connection ancestor erasure. Recursive adoption exhausts a budget after copying a parent and rolls back every copied archival row while retaining cache/journal state. Late media callbacks cannot erase a previously checked ancestor or remove its dependency edges and still return evidence. The incoming writer requires a matching active media reservation obtained before journal/SQLite locks; wrong-library and released reservations refuse. The archival recap fixtures explicitly use the trusted restore primitive; they do not prove the missing incoming recap adapter. Native-model tests do not establish human click/focus acceptance.

The [validation receipt](../benchmarks/sync-historical-citations-v1.json) records a full default debug pass: 1,503 passes and 73 explicit skips across 1,576 cases. All 21 new ordinary cases execute in debug, Thread Sanitizer and optimized builds. The 87-case sanitizer and optimized selections both pass without skips or failures; no sanitizer race warnings occur. Six current process/unit stages pass, followed by signed packaging, 16 offline SDK contracts, normal/indexed HTTP/MCP processes and actual old25 compatibility against the packaged CLI. The new test databases are absent from the 34-file app. All 34 extracted ZIP files match and strict ad-hoc signatures pass; the installed app's 15 files are unchanged. This is an unnotarized staged draft, not a product release.

The full debug stage passed before two process expectations were corrected for schema26. Its enclosing development-v20 pipeline remains failed at the later capture assertion; development-v21 retains the tag expectation failure. Product/Swift/test/Package inputs remain unchanged, while the two changed harness assertions are explicitly recorded. Actual old25 initialized collector, fresh reader/writer and backup-inspector compatibility passes against both debug and packaged executables. The first compatibility helper retained a sidecar comparison failure while Python readers remained open; explicit closure fixes it. The second retained an overly narrow expected backup-refusal message. Product refusals occurred in both attempts. Independent immutable reads of three flat-graph databases recompute typed global/body and native projection hashes, citation/pin bindings and logical accounting, preserving all ten SQLite files.

Archive-specific media/no-follow/physical cleanup/crash/scale, scoped erasure and retention using original-version fields, service-level reauthorization barriers, complete historical JSON/Markdown/save-recap workflows and human native UI acceptance remain open. The current transitive erasure closure starts from canonical owner scope; do not infer full historical-field scope or epoch coverage. Parent PR #103's model/native opt-in receipts apply only to its frozen sources. Local logs and failures remain under `.artifacts/sync-historical-citations-v1/`; the public input manifest fingerprints the source/check inputs, and the receipt records exact log hashes without publishing local corpus or environment state.

## Remaining work

- [x] Durable exact historical bodies and schema-26 citation representation.
- [x] Actual legacy fixtures, atomic migration refusals and cold-pin lifetime tests.
- [x] Typed incoming conversation/citation/pin writes and exact live/quiet-restore text.
- [x] Historical nested parent cards, read-only actions and recap invalidation model tests.
- [x] Full default debug, 87-case sanitizer/optimized selections and current process/SDK/staged-package checks.
- [x] Check actual fresh and already-running schema-25 executables against the development debug build.
- [x] Revalidate visible historical text selection and close it after source erasure; library switching cancels the watcher.
- [ ] Historical media playback leases/pins and stop-before-vault-close.
- [x] Exact flat persisted graph inspection, recursive budget rollback and late ancestor/edge mutation refusal.
- [ ] Expand archival media/admission/corruption/physical erasure/crash tests and nested independent graph review.
- [ ] Historical-field scoped erasure/retention and reauthorization barriers; complete JSON/Markdown/save-recap workflows.
- [ ] Complete typed incoming sources/recaps and the remaining graph adapters.
- [ ] Service lifecycle, enrollment, key rotation/revocation, production current-policy/erasure epochs, transport/providers and two-Mac acceptance.
- [ ] Sustained capture/power and notarized release; matched competitor benchmarks before any top-three claim.
