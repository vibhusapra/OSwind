# Recorded meeting workspace

Meetings now opens on **Recordings**, alongside the existing **Upcoming** calendar view. Record audio using the existing microphone/system-audio settings, import a file, select a recording session, and open an original transcript/clip. A failed recording start stays visible even when no audio work became active. Calendar access remains optional.

Sessions use the recording IDs already assigned to live microphone/system chunks and imported files. Similar titles, nearby timestamps or matching speaker labels do not merge unrelated conversations. A clip without a recording ID is its own session. Counts explicitly describe loaded clips; **Load older recordings** pages further back without hydrating transcript bodies.

Live coverage is the union of observed source intervals. Overlapping channels are counted once and gaps remain gaps. Clips without a recorded interval—including imports and older recordings with unknown timing—show their retained clip duration and a saved date. That date is not presented as the original meeting time or proof of import provenance. Speaker names remain local source annotations.

The new SQLite index is derived metadata, rebuilt from canonical audio sources. SQL triggers cover ordinary source updates/deletes, older writers and restore/incoming adapters. It stores recording identifiers, dates and source metadata, with no copied transcript or audio. Initial installation/repair still scans audio payloads to build this index; its large-archive cost has not yet been benchmarked. The steady-state page test denies canonical payload reads while listing recordings.

Ephemeral references belong to the exact open store and carry a per-row nonce. Updates, regrouping, deletion/recreation, foreign libraries and closed stores refuse stale source opening. Metadata pages retain values rather than vault descriptors. UI publication rechecks current settings; opening uses the normal source/detail path. Read jobs belong to the actual app departure registry, and a previous view's disappearance cannot clear a newer appearance.

## Evidence so far

- The source-pinned development run at `c108699` passed **17 selected native Debug methods**, with no skips: 16 new Core/App/native methods plus the existing real-Keychain three-library/all-13-kind sync regression.
- Cases cover overlapping-channel/gap accounting, import dates, byte-distinct Unicode IDs, equal-time pagination, privacy exclusions advancing cursors, current-policy source refusal, stale/foreign references, source SQL updates, projection repair and source-kind changes.
- App cases cover a policy change after reading but before publication, a foreign page, old/new appearance ordering and actual AppSession departure joining a blocked page worker before close.
- An actual generated encrypted APFS fixture retains the value page after store close and verifies that the image detaches. The native sync regression preserves original account/private fields and all 13 data-kind counts after replay.
- The first 13-method development run passed behavioral checks, but visual review found three populated scenes showing an empty pane/stale status. Those original images remain retained as failed visual QA. The appearance lease, layout and render-state checks were corrected before the 17-method result.
- All six corrected normal/compact/empty light/dark scenes were inspected. A later UI-only refusal-caption change passed an eight-scene render case: the original six images are byte-identical, and both additional local-model refusal scenes were inspected. The owned missing executable fails before audio hardware startup.

An upstream merge after those runs changes an unrelated existing peer test and documentation. The new recording production code remains the tested version plus the separately checked refusal caption. No post-merge whole-suite result is claimed.

[Development receipt](../benchmarks/recorded-meetings-development-v1.json) · [Raw inputs, source snapshots, logs and authored renders](../benchmarks/recorded-meetings-development-raw-v1.zip).

## Remaining work

- [ ] Named recording sessions, durable reviewed calendar-occurrence links and session-scoped Ask/recaps with exact source scope.
- [ ] Initial cache installation/repair, large-archive metadata-page time and memory measurements; evaluate lazy first-use backfill if opening cost is material.
- [ ] Portable backup/restore and wider incoming/erase/privacy regression for the derived index.
- [ ] Current source sanitizer, optimized, broader app/source-lifecycle regression and release packaging.
- [ ] Recorded/Upcoming wrapper interaction, keyboard/VoiceOver and actual native record/import/open/playback flows.
- [ ] Physical microphone/system-audio, permission/device switching, transcription quality and power acceptance.

These are generated fixtures and offscreen components on one Mac. F042 and the full v0 remain unfinished; no feature status or competitive ranking is promoted. No microphone/system recording, playback or provider/API request was made by these tests.

## Reviewed components

![Recording sessions](../assets/recorded-meetings-v5-recordings-light.png)

[Dark](../assets/recorded-meetings-v5-recordings-dark.png) · [Compact light](../assets/recorded-meetings-v5-compact-light.png) · [Compact dark](../assets/recorded-meetings-v5-compact-dark.png).

![Visible local-model setup refusal](../assets/recorded-meetings-v5-setup-failure-light.png)

[Dark refusal](../assets/recorded-meetings-v5-setup-failure-dark.png) · [Empty light](../assets/recorded-meetings-v5-empty-light.png) · [Empty dark](../assets/recorded-meetings-v5-empty-dark.png).

## Untimed legacy-date correction

A follow-up normal Debug selection has **12passed /1explicit native skip /0failures**:10Core, appearance regression and an eight-scene UI case pass. The regex also selects the native-page class, whose required flag is deliberately absent. A legacy microphone clip without an end timestamp remains distinct from an established recording interval; its retained date does not imply an import. All eight current three-session/five-clip or empty/refusal scenes were inspected. The previous successful native17run and versioned images remain unchanged; no current whole native/sanitizer qualification is implied. [Correction receipt](../benchmarks/recorded-meetings-untimed-v1.json) · [Raw input/source/log/current renders](../benchmarks/recorded-meetings-untimed-raw-v1.zip).
