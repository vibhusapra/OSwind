# Standalone Accessibility text capture

Choose **Settings → Capture → Desktop memory → Text only · Accessibility**, or choose the same mode during first-run setup. Resume capture when ready. Text-only desktop capture requires Accessibility access; it does not use Screen Recording, enumerate screen sources, capture pixels, run OCR, or retain image/video/audio files. Audio services remain independently controlled in Audio settings.

Some applications expose little or no accessible text. OSwind skips missing, protected, oversized or incomplete context; it never falls back to screenshots. Choose a pixel mode explicitly when you want OCR or replay coverage.

## Scope and cadence

The selected app's complete accessible focused-window text is observed. Text-only mode cannot enforce a spatial screen crop or collect background displays. A saved display/crop scope pauses it until you explicitly choose **Use full focused-window text**. Invalid saved areas remain blocked. Other modes retain their existing selections and checks.

Light samples every 20 seconds, Balanced every five, and Detailed every two. App switches also trigger checks with the existing coalescing guard. Low Power Mode and serious/critical thermal pressure multiply the interval, and two minutes without input pauses automatic capture. Sleep, lock, permission loss, pause and library changes prevent further admission.

These are sampled text observations, not keystroke logging or continuous active-time sessions. Unchanged text is not repeatedly stored and does not extend the original source's timestamp. Native application coverage, missed changes, interval-aware session coalescing and physical energy still need their own qualification.

## Admission and data handling

- A complete bounded AX read supplies the source text and app/title/URL context. The normal app, private-title, secure-field and browser-domain checks apply. Browser URL absence fails closed when required by the saved policy.
- Up to 16,000 text characters / 65,536 UTF-8 bytes are accepted, with separate bounded app, bundle, title and URL fields. Empty accessible text does not produce a title-only source. Native tree node/message/deadline bounds still apply.
- Existing pattern masks process body, app name, title and URL before storage and hashing. They can miss personal information. The experimental learned import scanner is not silently enabled for live capture, and a text capture does not mint a model-check record.
- Text/vector preparation runs outside the UI actor and SQL writer. A second complete context read revalidates the window and privacy rules before publication. The source contains the first admitted text observation; the OS does not provide an atomic whole-tree snapshot.
- A descriptor-bound snapshot pins the exact saved configuration through commit. A changed, replaced or malformed policy refuses the prepared source. An input/activity reservation orders preparation and admission before close/full wipe; root replacement refuses publication.
- Pause, scope/privacy/mode changes and sleep invalidate the publication gate. Preparation is canceled and joined. Only the small final source transaction enters that gate; no model work is inside it.
- One memory-only digest of the last sanitized source suppresses repeated automatic capture while that source still matches the library. It is bounded to one digest/ID, includes text and source metadata, and is not a separate raw-text cache. Deleted/replaced sources and explicit manual captures are not indefinitely suppressed. The lookup avoids decoding an unbounded replacement payload.

Sources use the existing screen-source format with `display: accessibility-window`, empty OCR regions and no retained media. They participate in keyword/semantic search, evidence, exports, erasure and backups. That display label is interchange metadata, not a privacy attestation. Pattern masking, AX context availability and external copies remain limitations; no absence-of-PII claim is made.

## CLI and compatibility

`oswindctl capture-text [--app-bundle ID]` performs one strict manual capture using a saved text-only mode and its policy. It reports failure if no complete indexed source is saved. Ordinary `capture` also honors the selected mode. `capture-replay` refuses a saved text-only mode instead of switching to pixels. Commands do not request permissions.

`doctor` adds `desktopCaptureMode`, `screenRecordingRequiredForDesktop` and `desktopPermissionReady` while retaining its existing fields. Permission readiness does not establish an unlocked session or useful accessible text.

Schema 23 and the Memory interchange shape are unchanged. Quiet backup/restore preserves text-only mode but leaves automatic services off. A signed preceding schema-23 binary reads the text records, but its unknown-mode decoder blocks snapshot/replay capture before device access. Strict older backup-settings decoding refuses the new mode; use the newer app to restore these settings. Unknown future modes still disable capture rather than widening its scope.

## Verification

Focused core/controller checks pass, including no-pixel/OCR seams, required Accessibility access, exclusions, changed context, cancellation during reads/model preparation, identical-byte policy replacement, root substitution, actual wipe ordering, dedupe, source deletion/manual capture and quiet backup. Separate app-model checks cover explicit saved mode changes and save failures. Frozen full/native, selected TSan/optimized and signed-package qualification is pending.

The controlled duty fixture executes 100 explicit sequential capture attempts on one unchanged owned context: one source, 101 full reads and one source-embedding request. Ten later changed observations create ten additional sources, with 20 full reads and ten source-embedding requests. Source embedding is counted separately from passage indexing. No media files are created. These are controlled call/work counts, not elapsed profile timing, native AX IPC, CPU, battery life or competitor performance.

Twelve light/dark AppKit component renders cover ready text mode, unresolved crop, privacy, onboarding, snapshots and replay. Selected ready/crop/onboarding layouts were reviewed. Debug component rendering does not start configured services. This is separate from permissioned signed-app interaction.

The CLI process probe has an explicitly absent UUID target and separate authored interchange sources. On the current locked host, native capture refuses at the lock guard before target lookup. Imported interchange fixtures are not reported as actual AX capture. Older-client refusal, media-free portability and quiet restore are independently checked.

Retained development receipts include a test-only backup-API compilation error; an interrupted root-substitution test that suspended every fake read instead of just the first (with two verified owned roots cleaned); and a process assertion that mistook an empty audio staging directory for a media file. The corrected process check still rejects every file or symlink in media buckets. No product/media-loss failure is inferred from these harness issues.

## Remaining acceptance

- [ ] Frozen full native/model, selected sanitizer/optimized and signed process/package qualification for this source.
- [ ] Actual signed-app permission/setup, native AX window/browser/secure-field transitions and older Mac/macOS coverage.
- [ ] Representative application AX completeness and natural multilingual/editing workloads.
- [ ] Sustained text-only versus snapshot/replay energy, CPU, storage and missed-change measurements with idle controls.
- [ ] Coalesced active-time/session visibility and matched competitor application workloads.

The updated [comparison](landscape.html) contains 20 profiles and 77 requirements. F077 is partial; broad parity, physical power and a top-three ranking remain open.
