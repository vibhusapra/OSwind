# OSwind delivery ledger

Updated 2026-10-22, America/Los_Angeles. Goal remains active. The previous interrupted goal turn made no tool progress; this turn created the implementation and verified the evidence below.

The full objective is an open-source macOS desktop-memory product with meaningful broad parity, local GPU inference, optional BYOK, great daily-use design, sustained performance, current research, tests, progress tracking and comparative benchmarks. **Feature completeness and top-three placement are not established.** Remaining work is preserved in the 72-row [feature ledger](features.json), its [interactive report](landscape.html) and the release gates here.

## Implemented and directly verified

- Native Swift package builds in debug and release on macOS 26.6.2 / Swift 6.3.3 / M5 Max. Ad-hoc signed .app packages successfully; a debug app process ran with isolated sample data.
- 29 XCTest cases pass: durable SQLite/FTS, Unicode, metadata/vector preservation, filters, retention/storage compaction, transactional import rollback, redaction, asset traversal/symlink rejection, concurrent readers/writers, API/MCP protocol, local model endpoint boundaries, WAV encoding, power policy, summary sampling, reasoning cleanup, actual Vision OCR.
- CLI durable note/search and real stdio MCP initialize/list/search smoke pass. Live loopback HTTP health/stats/search/get pass; unauthorized requests return 401, browser Origin and bad Host return 403.
- Apple Intelligence answered the local synthetic ownership question with the correct owner and [1] citation (~0.70 seconds in a repeated sample).
- Ollama qwen3:4b answered the same question with correct owner and [1] (~3.75 seconds warm sample). Runtime `ollama ps` reported 100% GPU, 8192 context. Reasoning text is stripped before display.
- Local Whisper base.en model downloaded with SHA256 verification; official public JFK WAV transcribed to the expected words. Installed whisper.cpp initializes the Metal backend. Continuous mic/system capture and end-to-end streaming remain unverified.
- Vision OCR read a generated 1600×900 text fixture, including the secret string used to verify redaction, in ~250–300 ms. This is not a broad OCR accuracy benchmark.
- 1,000-row debug and 10,000-row release synthetic retrieval benchmarks saved. 10k hybrid p95 ~21.7 ms, hit@5 1.0 and MRR .833; keyword MRR 1.0; semantic-only hit@5 .583. The narrow repeated-topic fixture favors keyword matching and is not a competitor benchmark.
- Paused debug app sampled for 65 seconds while locked: median RSS ~155 MiB. This is not active-capture power use; ps CPU is a lifetime average.
- Real targeted-window capture now passes on an unlocked Mac: 5 OCR regions, correct bundle identity, indexed synthetic marker and retained image (~0.49–0.67 s samples). The real-window secret fixture stores redacted text and no image. App/title exclusions create no rows; deletion removes the image and FTS entry. `scripts/live-capture-smoke.py` reproduces these checks using isolated temporary apps and data. This does not prove automatic foreground/app-switch behavior, browser URL privacy or audio capture.
- CLI attempted capture while the Mac was locked and correctly reported `Locked · capture suspended`. Initial native UI automation could not proceed because the Mac was locked; the later unlocked state enabled targeted synthetic capture verification. No attempt was made to bypass the lock.
- Native sample workspace rendered from its own NSHostingView and visually inspected without reading the desktop; search-mode label wrapping was fixed. Live keyboard, permissions and capture interactions remain unverified. Sample render is saved in `assets/workspace-sample.png`; a light-mode minimum-window layout and the Ask view were also rendered and inspected. Added appearance-aware accent contrast and a visible audio-only recording state.
- Interactive research report reviewed in an in-app browser at desktop and narrow layout; feature filtering works (vault query: 1 of 72 requirements). Repaired a JavaScript newline escaping error found during review.

## Implemented, broader runtime checks still needed

- ScreenCaptureKit capture, Vision + Accessibility context, JPEG retention, focused window/all display modes with excluded-app/browser masking, raw-image suppression on redaction, generation-token cancellation.
- Adaptive capture profiles, app-switch triggers, idle/lock/sleep handling, thermal/low-power backoff and change detection.
- Native search/timeline/cards/inspector, tags/favorites/notes, Ask source cards, coverage-aware recap samples, insights and capture health.
- Microphone conversion and system-audio stream; 30-second chunks; silence gating; bounded queue; short-session final flush; cancellable local Whisper jobs. Pause discards pending audio; explicit Stop audio finishes a final segment. Lock/sleep stop audio.
- Optional HTTPS BYOK adapters for OpenAI-compatible and Anthropic APIs, Keychain credentials, explicit remote context permission, no provider fallback or raw-media upload. Real paid vendor requests have not been run.
- Menu bar, global shortcut, timed pause, login items, setup and permission settings. Unlocked live UI, keyboard, permission, audio-device-change and relaunch verification are pending.
- Retention/storage pruning every five minutes, export/import, single/all deletion, script-based model setup and CI definition.

## Research delivered

16 primary-source offerings/projects: Screenpipe; original Rewind/Limitless; unrelated Rewind Desktop; Pieces; Littlebird; Recall; ScreenMemory; TimeScroll; two distinct Retraces; rem; Unlost; Pensieve/Memos; Minne; Omi; Granola. The report separates current and historical plans, annual equivalents, vendor claims, documented features, roadmap items, licensing and OSwind gaps. Competitor binaries have not been run.

## Next release gates (still open)

- [ ] Native interaction/permission flow, automatic foreground transitions, browser URL metadata/private-window tests. Real targeted screen capture and sampled layout rendering pass.
- [ ] End-to-end mic/system audio, short recordings, device changes, queue pressure and pause/lock boundaries. Subprocess cancellation is covered by an automated test.
- [ ] Stronger semantic/multilingual/multimodal retrieval and a diverse labeled relevance suite; current baseline is insufficient for state-of-the-art claims.
- [ ] Durable chats/follow-ups, natural-language time filters, scheduled routines, meeting sessions/diarization, calendar view and query-specific highlights.
- [ ] Encrypted vault/biometric unlock, stronger PII/image redaction, granular range/app/site erasure.
- [ ] Compressed video/media backup/restore, Markdown export, Rewind/Limitless migration, collector/plugin SDK.
- [ ] Model discovery/download UX, status/progress and provider contract tests beyond validation/parse paths.
- [ ] Real competitor runs on matched workloads; 100k+ scaling, storage growth, index lag, 24-hour capture/soak, fault injection and measured power.
- [ ] Accessibility/focus audit, supported older macOS/hardware coverage, notarized install/update channel.
- [x] [Draft PR #1](https://github.com/vibhusapra/OSwind/pull/1) opened; initial GitHub macOS build/tests/package/CLI smoke passed. Later commits require their own checks.

Personal sync, enterprise policy/team controls and other platforms remain visible future axes rather than being silently counted as complete. The user's current implementation target is macOS; those axes need an explicit delivery decision before any whole-market parity claim.

## Local artifacts

- App: `dist/OSwind.app` (excluded from Git; reproducible with `scripts/build-app.sh`). A locally ad-hoc signed copy was installed at `/Applications/OSwind.app`; rebuild/install after later commits to refresh it.
- Raw test/model/runtime logs and synthetic media: `.artifacts/` (excluded from Git).
- Reproducible public synthetic metrics: `benchmarks/`.
- Local synthetic verification databases: `.local/` (excluded from Git).
- Normal user data: `~/Library/Application Support/OSwind`; sample workspace is separate.

No real desktop memory, private file, credential or captured media is included in the public repository. Continuous capture has not been left running.
