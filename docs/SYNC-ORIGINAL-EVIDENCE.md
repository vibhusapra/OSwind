# Exact-version original evidence

Internal component qualified, 2026-10-31. An incoming citation can request an older source while this Mac has a newer offline edit. This layer materializes the admitted exact original as a read-only native `Memory`, separately from the current canonical source. Canonical incoming citation binding and native opening are still unfinished; [complete personal sync](PERSONAL-SYNC.md), F059, remains TODO.

## Storage and admission

`SyncOriginalEvidenceStore` explicitly installs a bounded metadata catalog alongside the typed version cache. Ordinary opening stays schema25/capture-disabled and installs no evidence catalog. Preparation creates an opaque UUID handle, role-relative media paths, exact recap-parent handles and a checksum; it creates no duplicate timeline source, identity, capture intent or journal operation. Source bodies remain in the existing cache.

Every prepare/read requires current record and media admission callbacks. Exact identity/content references never substitute a newer version. Scope, origin/generation, group/epoch, durability and protection schema are checked. The checksum binds the handle, owner/scope, exact object/content reference and original native payload. A final callback-free audit revalidates every visited node after all admission callbacks, so a late child callback cannot erase an already-checked ancestor and still return evidence. Failures roll back the transaction.

Read-only markers survive JSON serialization and prevent admission into canonical inserts/imports, current-source hydration, chat/recap saving, entity/visual/PII processing and outgoing source encoding. Intentional independent copies need a new source. Existing canonical Memory encoding stays unchanged when the marker is absent.

Recaps resolve exact original parent handles and native evidence hashes. Audio retains original session/transcript provenance without conveying local inference authority. Media paths are constrained to their image/audio/video role; paths alone do not authenticate files. The caller must verify current ownership/content/policy and retain leases or pins through playback. Owned tests verify actual no-follow bytes for all three roles and reject changed or symlinked files; a production media service is still required.

Canonical source erasure or a content-changing update clears cached originals and their projection metadata. Favorite/tag-only edits can retain an immutable original. Delete/recreate cannot revive an old handle. An authenticated exact dependency can be freshly reauthorized while the canonical current text stays unchanged. Quiet backup/restore preserves canonical history without cloning evidence handles or sync authority; portable provenance restoration remains open.

The metadata budget defaults to 64 MiB, internally configurable up to 8 GiB. Its logical charge is 192 bytes plus encoded paths/parents; the authored note fixture uses 196 bytes per projection. This excludes SQLite pages, cached bodies and journal/outbox storage. Recursion is bounded to depth32 and 512 shared visits; repeated visits can exhaust the bound before 512 unique objects. Full-cache preparation refuses atomically.

## Qualification

The [receipt](../benchmarks/sync-original-evidence-v1.json) records 18 passing logical stages over 869 unchanged inputs:

| Check | Result |
| --- | --- |
| Full suite with local model/native opt-ins | 1,555 defined; 1,541 pass; 14 explicit skips; zero failures |
| Thread Sanitizer selection | 424 defined; 411 pass; 13 skips; zero failures/race warnings |
| Optimized selection | 424 defined; 411 pass; 13 skips; zero failures |
| New ordinary cases | All 24 execute and pass in each build |
| Real own-child process death | Both pre/post-commit parents execute and pass in each build; worker entry skips normally |
| Independent reader | All 11,000 original rows, typed packets, projection bindings and actual native read-frame digests verified; ten refusal/corruption contracts pass |
| Staged package/processes | Terminal normal/held-reader, capture, conversation, recap, deletion, wipe, backup/interruption, normal/indexed HTTP/MCP and offline SDK pass |
| Independent package/native review | Strict signatures and normalized code payloads pass; all 34 extracted ZIP files match; three indexed graphs preserve membership/five scopes; five traced images and both terminal fixtures' images are absent; installed 15-file app unchanged |

The two-library test uses actual outgoing source/chat/turn/citation records, edits the receiver's canonical source offline, then materializes the exact concurrent original before canonical citation application. It preserves current text and creates no outgoing echo. Other received graph callbacks are fixture seams; this is not complete incoming graph sync or a native citation UI test.

Development exposed two retained bugs: a late parent-admission callback could erase the recap root after its check, and equal native payloads could let stale checksum metadata retarget a valid identity/content pair. The final graph audit and scope/version-bound checksum repair them. All six actual historical source/test snapshots and both failed runs remain retained. These checks detect stale/corrupt metadata; they do not protect against someone rewriting all local state and hashes.

The first broad driver stopped in a corruption helper: it treated SQLite TEXT as bytes before invoking the reader for that case. Its report/log remain unchanged. A corrected helper passes all ten contracts; the first four passing stages are reused only after their full input/log hashes are verified. The fourteen remaining stages run against identical product sources. The explicit real-model idle test passes after 134.423 seconds; a two-second owned-process stack sample during that wait is retained.

Parent PRs #101/#102 pass hosted CI. PR #100's earlier ordinary-lock hdiutil exit16 failure remains unexplained; later passing runs do not establish its cause.

## Authored warm scale

| Note sources | Original preparation | Original reads/JSON hashing | Added logical metadata |
| --- | ---: | ---: | ---: |
| 1,000 | 4.434 s | 3.204 s | 196,000 bytes |
| 10,000 | 42.692 s | 32.944 s | 1,960,000 bytes |

One optimized warm run per size, with outer batches of at most128. Preparation includes bounded body queries, exact cache checks, native projection, transactional metadata and final graph audits. Reads include bounded handle queries, exact native reads, full Memory encoding and framed SHA aggregation. Both phases follow separately timed outgoing preparation; canonical population/setup, model/privacy inference, media, transport and energy are excluded. Aggregate phase times are not individual interactive-open latency, end-to-end throughput or competitor measurements. The independent reader also still accepts the retained legacy outgoing fixture.

## Remaining delivery work

- [x] Immutable exact-version native projections, read-only admission fences, bounded metadata and exact recap/audio provenance.
- [x] Current callback/schema/scope checks, graph-wide final audit, erasure/restart and actual own-child recovery.
- [x] Full/TSan/optimized, independent scale/reader, staged package and process qualification.
- [ ] Bind canonical incoming citations to exact original handles and integrate native historical-evidence opening, including passage validation and unavailable states.
- [ ] Complete all incoming graph adapters, media ownership/leases/transport, production privacy and erasure/wipe epochs, and provenance restoration.
- [ ] Enrollment/Keychain, rotation/revocation, service lifecycle, native/CLI/backpressure workflows and actual provider/two-Mac acceptance.

All 78 requirement statuses remain unchanged. Broad parity, sustained capture/power and notarized distribution remain delivery goals.
