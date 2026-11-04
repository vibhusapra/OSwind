# Recording names and calendar associations — WIP

This is an unpublished backend on `codex/recording-session-links`. The latest qualified development package remains the PR165 build. Naming UI, metadata transport and current native calendar review are not implemented yet. F042, complete v0 parity and top-three acceptance remain open.

## Canonical user-authored data

Runtime `0c32217` adds `MemoryKind.recordingMetadata` (`recording-metadata`) within the existing canonical `memories` table. It uses the existing native source identity rather than adding a fourteenth canonical sync table. Names are separate user-authored records, not transcript edits or rebuildable-cache-only preferences. Naming preserves the audio IDs, original title/text/timestamps, recording ID and evidence hash. Session targets use exact UTF-8 recording IDs; legacy ungrouped targets use the same exact-evidence-version restriction as recording-scoped Ask.

Name snapshots have an open-store owner and an opaque metadata-row nonce. Editing compares the current snapshot inside a writer transaction and the current settings guard. Deletion/recreation, byte-distinct IDs, concurrent edits, changed/foreign audio and current privacy exclusions refuse stale edits. Multiple definitions are returned as a conflict; the edit API refuses to choose one by date or name. The conflict-management UI is still required.

`recorded_meeting_details` is a derived bounded metadata projection with built-in SQL triggers. It carries per-row revisions and joins the recording change nonce. Repair invalidates prepared metadata without scanning transcripts during installation; historical metadata rebuilding belongs to the later owned worker. Source-cache version 2 and canonical audio identity stay unchanged. Ready archive/revision/publication tests deny canonical payload reads and all SQL writes with a saved name present. The selected-name editing read still hydrates canonical evidence; the archive does not yet display the projected name.

`RecordingCalendarLink` contains the exact occurrence identity, recurrence/date fields, reviewed revision and library binding. It copies no event title, attendees, description or join URL. It is data, not Calendar permission, proof of attendance or execution authority. The live provider/access/selection/library/privacy/source checks and historical resolver must be implemented before a user-facing link action.

## Retained development evidence

- Initial Core source `36925f8`: **73 selected Debug methods passed**, zero skips/failures, including 12 new metadata methods, 24 existing calendar methods and actual owned encrypted-image detach. Names survive reopening and quiet backup/restore; newly arriving clips with the same exact session ID resolve the name. Original audio remains unchanged.
- Desired-contract source `020eb05`, with production identical to that initial source: **four failed methods / five assertion issues / zero unexpected issues**. Identical metadata recreation accepted a retired edit snapshot; canonically equivalent but byte-different IDs could retarget it; names did not advance the recording revision; and an obsolete prepared name could publish. Original logs, source bytes and compiled engine remain retained.
- Current runtime `0c32217`: **107 selected Debug methods passed**, zero skips/failures. All four prior failures pass, with new rollback, deferred repair, read-only ready traversal, built-in SQL writer and stale-embedding controls. This includes 21 metadata and 25 existing portable-record methods. Existing portable formats pass; transport of the new metadata is still explicitly refused.
- One additional calendar/quiet-restore method passed on byte-identical production. Calendar was enabled before backup and a non-nil association persisted. After quiet restore the association survives, while Calendar remains disabled with no selected IDs or bound authorization. A deliberately different event date does not rewrite recording time, and event title/attendee/join token remain absent from the stored metadata.

Local evidence is retained in `.artifacts/recording-session-links-v1/`: source/input hashes, separate actual engines, the original failed probes, successful `development-v1`, `development-v2` and the single new `development-v3` control. No successful control or package was rebuilt merely to attach commit metadata. The broad qualification, rendered components, timings and normal package in [PR165](https://github.com/vibhusapra/OSwind/pull/165) qualify its previous runtime, not this backend.

## Required before publishing the feature

- [ ] Complete typed portable metadata using the source-origin recording namespace and exact source-version references; add incoming/outgoing dependency, privacy, erasure, native, backup and actual old-client controls. Remove the temporary `SyncSourceBody` refusal only when these adapters are complete.
- [ ] Display names/conflicts using thin metadata during archive preparation; preserve page/window consistency, privacy invalidation, cancellation, joined departure and cursor coverage. Define legacy-version revalidation without scanning unrelated transcript bodies.
- [ ] Add the registry-owned name editor and explicit conflict review/removal. No database work on the main actor or silent winner selection.
- [ ] Add explicit calendar choice and historical occurrence resolution, with fresh native access, selected calendars, library lifetime, privacy, provider revision and source validation before saving. Peer/restored references remain dormant until current local review. No title/time matching or automatic joining/invitations.
- [ ] Run current optimized/Thread Sanitizer, native metadata/real-Keychain, whole affected regression, meaningful changed-runtime performance, light/dark/compact/error/conflict renders and normal packaging.
- [ ] Keep the broader physical microphone/system-audio, native wrapper/keyboard/VoiceOver, ASR/device quality, controlled power/current automatic24h, separate owner/peer failures and production distribution gates visible.

[Core types and APIs](../Sources/OSwindCore/RecordingDetails.swift) · [Derived metadata index](../Sources/OSwindCore/RecordingDetailsSchema.swift) · [Owned behavior controls](../Tests/OSwindCoreTests/RecordingDetailsTests.swift).
