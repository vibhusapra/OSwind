# OSwind delivery ledger

Updated 2026-10-23, America/Los_Angeles. Goal remains active. This ledger records implementation, direct evidence and remaining release gates.

The full objective is an open-source macOS desktop-memory product with meaningful broad parity, local GPU inference, optional BYOK, great daily-use design, sustained performance, current research, tests, progress tracking and comparative benchmarks. **Feature completeness and top-three placement are not established.** Remaining work is preserved in the 72-row [feature ledger](features.json), its [interactive report](landscape.html) and the release gates here.

## Implemented and directly verified

- Native Swift package builds in debug and release on macOS 26.6.2 / Swift 6.3.3 / M5 Max. Ad-hoc signed .app packages successfully; a debug app process ran with isolated sample data.
- 84 automated XCTest cases pass (plus one opt-in real-runtime check): durable SQLite/FTS, Unicode, metadata/vector preservation, filters, retention/storage compaction, transactional import rollback, redaction, asset traversal/symlink rejection, concurrent readers/writers, API/MCP protocol, local model endpoint boundaries, WAV encoding, power policy, summary sampling, reasoning cleanup, actual Vision OCR.
- CLI durable note/search and real stdio MCP initialize/list/search smoke pass. Live loopback HTTP health/stats/search/get pass; unauthorized requests return 401, browser Origin and bad Host return 403.
- Apple Intelligence answered the local synthetic ownership question with the correct owner and [1] citation (~0.70 seconds in a repeated sample).
- Ollama qwen3:4b answered the same question with correct owner and [1] (~3.75 seconds warm sample). Runtime `ollama ps` reported 100% GPU, 8192 context. Reasoning text is stripped before display.
- Local Whisper base.en model downloaded with SHA256 verification; official public JFK WAV transcribed to the expected words. Installed whisper.cpp initializes the Metal backend. Continuous mic/system capture and end-to-end streaming remain unverified.
- Vision OCR read a generated 1600×900 text fixture, including the secret string used to verify redaction, in ~250–300 ms. This is not a broad OCR accuracy benchmark.
- 1,000-row debug and 10,000-row release synthetic retrieval benchmarks saved. 10k hybrid p95 ~21.7 ms, hit@5 1.0 and MRR .833; keyword MRR 1.0; semantic-only hit@5 .583. The narrow repeated-topic fixture favors keyword matching and is not a competitor benchmark.
- Paused debug app sampled for 65 seconds while locked: median RSS ~155 MiB. This is not active-capture power use; ps CPU is a lifetime average.
- Real targeted-window capture now passes on an unlocked Mac: 5 OCR regions, correct bundle identity, indexed synthetic marker and retained image (~0.49–0.67 s samples). The real-window secret fixture stores redacted text and no image. App/title exclusions create no rows; deletion removes the image and FTS entry. `scripts/live-capture-smoke.py` reproduces these checks using isolated temporary apps and data. This does not prove automatic foreground/app-switch behavior, browser URL privacy or audio capture.
- CLI attempted capture while the Mac was locked and correctly reported `Locked · capture suspended`. Initial native UI automation could not proceed because the Mac was locked; the later unlocked state enabled targeted synthetic capture verification. No attempt was made to bypass the lock.
- Native sample workspace rendered from its own NSHostingView and visually inspected without reading the desktop; search-mode label wrapping was fixed. An unlocked native session verified model discovery/preparation, Indexed selection, a semantic result and Command-K search focus. The global hotkey raised the window but failed to focus search; a fix is implemented and awaits live retest after the Mac relocked. Permission grants, closed-window reopening and broader keyboard/accessibility flows remain open. Sample render is saved in `assets/workspace-sample.png`; a light-mode minimum-window layout and the Ask view were also rendered and inspected. Added appearance-aware accent contrast and a visible audio-only recording state.
- Interactive research report reviewed in an in-app browser at desktop and narrow layout; feature filtering works (vault query: 1 of 72 requirements). Repaired a JavaScript newline escaping error found during review.

- Optional Qwen3-Embedding 0.6B local index runs on the Mac GPU. Model digests/dimensions version the vectors; batch writes check content hashes and cannot resurrect deleted evidence. Native settings and CLI provide discovery, download progress/cancellation, runtime residency and resumable indexing. Shared search powers UI, answers, HTTP and MCP; unavailable Hybrid semantics explicitly fall back to keyword results. Semantic-only fails explicitly. Existing user model daemons are never replaced.
- A 32-document / 35-query authored relevance fixture includes 31 answerable questions (paraphrase, code, multilingual and filtered) and 4 unanswerable questions. Qwen3 hybrid and semantic both achieved Recall@5/MRR@5 of 1.0; hybrid p95 ~92 ms. Apple hybrid Recall@5 .871, MRR .720, p95 ~4.7 ms. This small fixture does not establish broad superiority. All modes returned candidates for all unanswerable queries: abstention remains unsolved. See `benchmarks/README.md`.
- Version-1 store migration, content/version races, stale vectors, cross-language fusion, cloud model aliases and explicit fallback have regression coverage. The real managed-server lifecycle is tested only when `OSWIND_TEST_MANAGED_RUNTIME=1` is set.
- The Models page was rendered and inspected. An unlocked native session subsequently prepared a six-vector index, selected Indexed and displayed the expected synthetic result. Download/cancel and broader failure/permission interaction review remain open.

- Durable saved chats now pass separate-process create/ask/follow-up/reopen/export/delete checks. Ten conversation tests cover source/session erasure races, transaction rollback, retention, schema-2 migration, future-schema refusal and source hydration; a claim-rendering test rejects invalid citations. Repeated source text is not stored in chat payloads.
- Real local chat smoke passes with Qwen3 and Apple: correct owner, Friday follow-up and [1] citations. Apple now uses guided source-number claims after the smoke exposed missing citations, false abstention and answering the earlier question. The current-question prompt was corrected; this tiny smoke is not a grounding/abstention accuracy study. `benchmarks/conversation-local-v1.json` records observed responses/timings.
- Chat layouts were rendered and visually inspected in dark mode and at the minimum light-mode window size. Saved-chat native keyboard interaction remains pending; rendered layouts and process checks are separate evidence.

- Exact vector scanning now uses a bounded top-candidate heap and reads SQLite vector bytes without copying each vector. Brute-force, filters, ties, malformed-vector and duplicate-index tests preserve correctness. Apple/Qwen relevance metrics did not regress. Paired 100k synthetic 1024-dimensional runs measured p95 ~126 → ~115 ms for the all-candidate scan, process peak RSS ~36 → ~25 MiB. The 10k timings are broadly flat; these development runs do not establish universal performance.

- **Million-vector performance gate failed:** 1m × 1024-dimensional synthetic vectors used ~5.33 GB on disk, ~235 s to ingest. Exact identity stayed correct, but unfiltered all-candidate p50 ~1.31 s / p95 ~22.42 s; thresholded p95 ~1.22 s and half-archive app-filter p95 ~.88 s. The cause of the tail spike is not established. Preserve this result and prioritize ANN/partitioning, cold/warm instrumentation and capture-contention checks. These are CPU exact-scan timings, not GPU/model timings.

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
- [ ] Extend the new multilingual relevance suite to realistic larger archives, adversarial questions and abstention; add multimodal retrieval. Qwen3 local embedding and the authored 35-query suite are delivered; state-of-the-art claims remain unproven.
- [ ] Natural-language time filters, scheduled routines, meeting sessions/diarization, calendar view and query-specific highlights. Durable chats/follow-ups and chat Markdown export are delivered with v0 history bounds; broader conversation/grounding evaluation remains open.
- [ ] Encrypted vault/biometric unlock, stronger PII/image redaction, granular range/app/site erasure.
- [ ] Compressed video/media backup/restore, Markdown export, Rewind/Limitless migration, collector/plugin SDK.
- [ ] Unlocked interaction review of delivered model discovery/download/index UX; broader provider contracts, failure recovery and backend/version matrix. Local-model API mocks, real pull, embedding, runtime and managed-server checks are covered.
- [ ] Real competitor runs on matched workloads; larger relevance/scaling validation, storage growth, index lag, 24-hour capture/soak, fault injection and measured power.
- [ ] Accessibility/focus audit, supported older macOS/hardware coverage, notarized install/update channel.
- [x] [Draft PR #5](https://github.com/vibhusapra/OSwind/pull/5) adds journaled native indexing and its recovery/recall/performance checks; current-head macOS CI passed.
- [x] [Draft PR #4](https://github.com/vibhusapra/OSwind/pull/4) adds bounded exact scanning and preserves the failed million-vector gate; current-head macOS CI passed.
- [x] [Draft PR #3](https://github.com/vibhusapra/OSwind/pull/3) adds durable conversations, follow-up context and source-linked erasure; current-head macOS CI passed.
- [x] [Draft PR #2](https://github.com/vibhusapra/OSwind/pull/2) adds local GPU retrieval/model setup and relevance evaluation; current-head macOS CI passed.
- [x] [Draft PR #1](https://github.com/vibhusapra/OSwind/pull/1) opened; initial GitHub macOS build/tests/package/CLI smoke passed. Later commits require their own checks.

Personal sync, enterprise policy/team controls and other platforms remain visible future axes rather than being silently counted as complete. The user's current implementation target is macOS; those axes need an explicit delivery decision before any whole-market parity claim.

## Indexed retrieval milestone — draft PR #5

[Draft PR #5](https://github.com/vibhusapra/OSwind/pull/5) implements a schema-4 vector mutation journal, stable never-reused native keys, model/store-isolated HNSW snapshots, checksum verification, cross-process build leases, cancellation, low-power/thermal deferral, live SQL filters, fresh-change exact search and float32 candidate reranking. Graphs contain derived vectors/keys, not source text. Disposable cache files are evicted before recorded evidence under storage pressure; Delete all clears graph files and rotates store identity. Idle maintenance checkpoints changed graphs only. Manual cancel pauses automatic construction until resumed; completed embeddings remain, partial graph construction restarts.

Current checks: 76 automated tests pass (plus one skipped opt-in runtime check); 12 cache/retrieval tests also pass ThreadSanitizer. Schema-3 vectors/FTS migrate without reprocessing. Real CLI Qwen3 verification loads a saved graph and returns the correct synthetic ownership note. Offline-model CLI/HTTP/MCP indexed process smoke and durable-chat process smoke pass. Apple/Qwen relevance metrics did not regress on the authored 35-query suite. Native model settings/preparation, Indexed selection, semantic result and Command-K worked during the unlocked session. A global-hotkey focus bug is fixed in code but live retest is blocked by the subsequent lock. Controlled targeted capture again passed (~0.77–0.85 s, five OCR regions), including redaction, raw-image suppression, exclusions and deletion.

Pinned dependency: USearch 2.26.5 / resolved NumKong 7.8.5, Apache-2.0; notices/licenses bundled. At 100k × 1024 dimensions the actual bounded-parallel graph prepared in ~252 s. Whole-path unfiltered self-query p95 was ~66.8 ms indexed / 132 ms exact; half-app indexed was slower (~399 / 99 ms). Automatic therefore keeps every filtered query exact and only indexes unfiltered scopes at 20k+ vectors. Explicit Indexed remains an approximation choice. Sixteen non-self queries per scope recovered all exact top-10 neighbors in this small synthetic test; unfiltered p95 ~58 / 124 ms, filtered ~456 / 106 ms. Native-only exploration and full SQLite results remain separately labeled in the benchmark ledger.

The retained million-vector ANN build is running; no result is claimed. Next gates: million/cold tails, independent realistic recall, write contention, scope/count/statistics costs (including tags), long-run memory/power, orphan/fork/restore recovery and broader UI/audio/parity work. Vault encryption, routines, meeting workflows, migration/backup and real competitor runs remain open.

## Long-source evidence and query highlights — draft PR #6

[Draft PR #6](https://github.com/vibhusapra/OSwind/pull/6) replaces first-500-character duplicate suppression with full source/context fingerprints and first-800-character context with query-anchored lexical windows. Distant terms can select a second passage; Unicode stays composed and ellipses mark omissions. Recaps/unanchored queries retain opening/ending text. Native cards/source inspector show asynchronously selected highlighted excerpts. A rendered synthetic long-note search was reviewed; compact snippets now keep the deadline visible. Live interaction remains separate from the app's own layout render.

Source date/kind revisions now invalidate saved and in-flight answers while leaving content-compatible embeddings available. CLI one-off/chat Ask accept model/endpoint overrides; one-off scope flags are applied and questions sanitized. Output-limit stop reasons fail without appending a partial chat answer. Offline provider process tests verify this boundary. Local Ollama generation does not read BYOK accounts. Recent user questions resolve retrieval; generation receives the current question and fresh evidence.

Current validation: 84 tests pass, one opt-in runtime case skipped. Long-note evidence mode, model/endpoint/limit process smoke, indexed API/MCP and durable chat checks pass. Three Apple and two pinned Qwen3 Instruct trials passed owner/deadline assignment and an unsupported budget question on the authored two-note fixture. Native rendering shows the late deadline inside the highlighted card. Broader live UI, semantic support and adversarial questions remain open.

The testing exposed real model failures and a weak initial grader. A source-by-source Apple experiment generated a false owner and was discarded. The installed short Qwen tag matched a thinking-only model; its ~10–26 s development answers sometimes exhausted the output budget or exposed unfinished metareasoning. The explicit Instruct tag passed the stricter fixture, with first observed answer ~1.3 s and later answers ~0.12–0.46 s. These tiny concurrent-load observations are not general quality or performance rankings. Historical failures and current trial metadata are in the benchmark ledger. Setup/default model presets now use the explicit non-thinking version; selected user model names remain intact.

Remaining evidence work: semantic chunk indexing beyond embedding input limits, held-out multilingual/long-archive grounding, source/citation entailment, robust abstention, token/context budgets and prompt-injection evaluation. Query-only image boxes remain pending; the delivered query highlights are text excerpts.

## Local artifacts

- App: `dist/OSwind.app` (excluded from Git; reproducible with `scripts/build-app.sh`). The current tested release preview (fe51c8c) is installed at `/Applications/OSwind.app` and passes strict code-signature verification; `dist/OSwind-macos.zip` is packaged. Later code changes require rebuilding/reinstalling.
- Raw test/model/runtime logs and synthetic media: `.artifacts/` (excluded from Git).
- Reproducible public synthetic metrics: `benchmarks/`.
- Local synthetic verification databases: `.local/` (excluded from Git).
- Normal user data: `~/Library/Application Support/OSwind`; sample workspace is separate.

No real desktop memory, private file, credential or captured media is included in the public repository. Continuous capture has not been left running.
