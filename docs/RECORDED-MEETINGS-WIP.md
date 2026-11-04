# Recorded meeting workspace

Meetings now opens on **Recordings**, alongside the existing **Upcoming** calendar view. Record audio using the existing microphone/system-audio settings, import a file, select a recording session, and open an original transcript/clip. A failed recording start stays visible even when no audio work became active. Calendar access remains optional.

Sessions use the recording IDs already assigned to live microphone/system chunks and imported files. Similar titles, nearby timestamps or matching speaker labels do not merge unrelated conversations. A clip without a recording ID is its own session. Counts explicitly describe loaded clips; **Load older recordings** pages further back without hydrating transcript bodies.

Live coverage is the union of observed source intervals. Overlapping channels are counted once and gaps remain gaps. Clips without a recorded interval—including imports and older recordings with unknown timing—show their retained clip duration and a saved date. That date is not presented as the original meeting time or proof of import provenance. Speaker names remain local source annotations.

The new SQLite index is derived metadata, rebuilt from canonical audio sources. SQL triggers cover ordinary source updates/deletes, older writers and restore/incoming adapters. It stores recording identifiers, dates and source metadata, with no copied transcript or audio. Opening/repair installs the cache and write-through triggers without a historical transcript scan. The first Recordings load builds historical metadata in its cancellable worker; measured first-use and steady-state costs are reported below. The steady-state page test denies canonical payload reads while listing recordings.

Ephemeral references belong to the exact open store and carry a per-row nonce. Updates, regrouping, deletion/recreation, foreign libraries and closed stores refuse stale source opening. Metadata pages retain values rather than vault descriptors. UI publication rechecks current settings; opening uses the normal source/detail path. Read jobs belong to the actual app departure registry, and a previous view's disappearance cannot clear a newer appearance.

## Initial workspace evidence

- The source-pinned development run at `c108699` passed **17 selected native Debug methods**, with no skips: 16 new Core/App/native methods plus the existing real-Keychain three-library/all-13-kind sync regression.
- Cases cover overlapping-channel/gap accounting, import dates, byte-distinct Unicode IDs, equal-time pagination, privacy exclusions advancing cursors, current-policy source refusal, stale/foreign references, source SQL updates, projection repair and source-kind changes.
- App cases cover a policy change after reading but before publication, a foreign page, old/new appearance ordering and actual AppSession departure joining a blocked page worker before close.
- An actual generated encrypted APFS fixture retains the value page after store close and verifies that the image detaches. The native sync regression preserves original account/private fields and all 13 data-kind counts after replay.
- The first 13-method development run passed behavioral checks, but visual review found three populated scenes showing an empty pane/stale status. Those original images remain retained as failed visual QA. The appearance lease, layout and render-state checks were corrected before the 17-method result.
- All six corrected normal/compact/empty light/dark scenes were inspected. A later UI-only refusal-caption change passed an eight-scene render case: the original six images are byte-identical, and both additional local-model refusal scenes were inspected. The owned missing executable fails before audio hardware startup.

At that stage, an upstream merge changed an unrelated peer test and documentation; the recording implementation differed only by the separately checked refusal caption. The later indexing/lifecycle changes and their selected qualification are recorded below. No whole-current-suite result is claimed.

[Development receipt](../benchmarks/recorded-meetings-development-v1.json) · [Raw inputs, source snapshots, logs and authored renders](../benchmarks/recorded-meetings-development-raw-v1.zip).

## Remaining work

- [ ] Named recording sessions, durable reviewed calendar-occurrence links and session-scoped Ask/recaps with exact source scope.
- [x] Measure first-open/first-use metadata costs and move historical backfill into the cancellable Recordings load; retain all process latency/RSS observations.
- [x] Generated portable backup/restore, incoming-origin projection/deletion and current privacy/erasure regression for the derived index.
- [x] Selected current source optimized/sanitizer regression and strict ad-hoc development packaging; whole-current-suite and hosted qualification remain open.
- [ ] Controlled session-ID length/NUL edge cases, incoming-change UI invalidation and actual list-publication/frame-cost audit.
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

## Deferred archive indexing and current selected checks

Opening an existing archive now installs write-through metadata triggers without scanning old transcript bodies. Its first **Recordings** load performs that scan in the owned, cancellable worker and commits readiness atomically. Failure or cancellation rolls rows and readiness back together. New empty libraries are ready immediately; pending and ready reopens preserve new writer rows and existing nonces. Own app deletion and erasure clear or refresh recording previews.

The source-pinned optimized and Thread Sanitizer runs each selected **319 methods: 304 passed, 15 skipped, zero failures**. Every skip was audited: nine child-entry helpers, three opt-in scale probes, two probes requiring the exact prior-format client, and one component-render case. The recorded-workspace CI subset has 26 methods: 25 passed and that one render case skipped locally. The broader runs include actual encrypted APFS page retention/detach, real-Keychain three-library/all-13-kind replay, original private-field preservation, backup/restore, erasure, privacy, import, incoming projection and crash-recovery regressions. There was no sanitizer race report. This does not supersede earlier owner/peer broad WIP failures or qualify the whole current suite.

Two authored shapes were measured on one Mac17,6 with 128 GiB RAM: 20,000 audio sources with 768-byte text and 256 sources with 131,072-byte text. No recognized speech or audio media is involved. Both optimized frozen executables opened identical generated databases in eight counterbalanced pairs per shape, with three subsequent process opens per trial. Each new trial also verified its first page and all exact source IDs. Filesystem caches were not flushed; an older manual capture soak remained active.

| Authored archive | Median first CLI open, ms | Median first Recordings page, ms | Maximum first CLI open, ms |
|---|---:|---:|---:|
| 20,000 short clips | 207.530 → 34.388 | 15.155 → 190.210 | 236.971 → 540.544 |
| 256 long saved transcripts | 74.301 → 28.953 | 7.966 → 51.319 | 80.152 → 31.117 |

The scan moved to deliberate first use; total work was not eliminated. The first-lazy-open 540.544 ms outlier remains in the maximum and small-sample p95; its cause is unproved. Subsequent process opens, every traversal page, eleven repeat first-page timings per worker, process RSS and storage-state observations are retained in the data. These are component timings, not GUI frame/launch, energy, physical-device, automatic 24-hour or competitor-ranking results.

All **290 observations** remain available: 130 from the original predecessor/eager comparison and 160 from the eager/deferred comparison. No successful experiment was rerun just for metadata. A failed 24-method development run is also preserved: its incoming fixture tried peer apply before draining a receiver local write. The fixture sequence alone was corrected and passed in isolation; no production sync fix is claimed.

A separate normal release build from the qualified source was packaged into a new local development app, with all three executables executable and `codesign --verify --deep --strict` passing. Frozen comparator/test engines were preserved unchanged. The first packaging reviewer incorrectly required the normal release executable to equal the optimized-test executable byte for byte. A versioned read-only review corrected that assumption against the retained successful build/package; it did not rebuild, resign or rerun tests. The packaged CLI also passed an owned empty-library stats smoke. This is ad-hoc development packaging, without notarization or current live GUI/audio acceptance. Prior v5 component images above are retained; their render case was not repeated for these metadata changes.

[Source/input/test/package/performance receipt](../benchmarks/recorded-meetings-startup-v1.json) · [Raw observations, original failures, source snapshots and generators](../benchmarks/recorded-meetings-startup-raw-v1.zip) · [Current CI selection static review](../benchmarks/recorded-meetings-ci-selection-v2.json).
