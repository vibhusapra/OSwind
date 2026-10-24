# Portable Markdown and Obsidian export

Entity definitions, aliases, notes and membership corrections currently require a [full library backup](BACKUP.md); source JSON and Markdown exports do not preserve that entity layer.

Choose **Settings → Data → Markdown & Obsidian → Export Markdown library…**. Retained media is off by default. The export runs on a utility worker, shows progress beside the export control and supports Cancel. Other library transfers and library switching wait for that operation.

```bash
oswindctl --data /absolute/path/to/library export-markdown /absolute/path/to/new-folder
oswindctl --data /absolute/path/to/library export-markdown /absolute/path/to/new-folder --include-media
```

The source library must exist. Choose a new destination outside it. Existing files, folders and symlinks are refused, including a destination created by another process just before publication. No model download, embedding inference, cloud request, capture or permission prompt is needed.

Open the resulting folder as an Obsidian vault, or start with `index.md` in a Markdown reader:

- `index.md`: every exported source and conversation, linked using relative paths.
- `sources/<SHA256-of-source-ID>.md`: stable source names independent of titles or filesystem-sensitive IDs. YAML properties include the original ID, title/alias, kind, timestamp, application, bundle, tags, favorite, and optional end/session metadata. The body preserves complete source text, timed speech segments with recording-local speaker labels, or sampled replay frame times.
- `conversations/<SHA256-of-session-ID>.md`: every saved turn with question, answer, provider, scope, warnings and numbered links to exported source files. Source numbers restart for each answer. This path does not use the UI's 100-source/1,000-turn display limits.
- `media/`: optional copies of retained images, audio and replay clips, with local links from their owning source. Nothing downloads missing media.
- `export.json`: format/schema, creation time, source/turn exclusions and exported record/media counts.

No `.obsidian` settings, plugins or executable content are installed. Source filenames are opaque IDs; human titles/aliases and the index provide navigation. Custom daily-note layouts, readable filename options, an Obsidian plugin and incremental bidirectional synchronization remain future work.

## Privacy and snapshot behavior

A consistent SQLite snapshot keeps source records, citations and conversations from one point in time without holding the live store's lock. The privacy policy is copied when the operation starts. Current application/domain/title exclusions skip matching sources. If any cited source is omitted, the entire dependent conversation turn is omitted. Session titles are deliberately generic because their original title can reveal a hidden question.

Pattern redaction is reapplied to exported fields and timed text. Speech credential detection also hides sensitive timed speech. Detected or previously marked redaction suppresses all raw media for that record; the current retain-images setting additionally controls image/video inclusion. These checks remain best effort and cannot prove that arbitrary pixels or speech contain no private information.

Captured/model text is written as literal text rather than active Markdown/HTML/remote embeds. YAML values also encode Markdown punctuation for readers that display front matter as ordinary text. Generated source and media links remain navigable. This preserves the captured text; it does not give retrieved content permission to run.

The destination is an **independent, unencrypted copy**. Later OSwind edits, privacy changes, retention and deletion do not modify it. Keychain credentials, API tokens, settings, vectors, downloaded models and speaker embeddings are absent. Use a [full backup](BACKUP.md) for restorable library state; this export is a reading/interchange format, not a lossless database restore.

Each row is read and written separately, and Foundation temporaries are drained per record/turn. The index and conversations stream to disk; a scratch SQLite link index avoids an archive-sized in-memory source map. Individual source payloads keep the existing 128 MiB bound. Temporary snapshots can require substantial disk space, including the source database's vectors, even though vectors are not exported.

Media copies use descriptor-relative, no-follow reads with change detection. If a retained file is missing, replaced, changes while being read or has an unsupported suffix, the operation fails without publishing a partial folder. Retry after capture/retention settles, or choose text only. A cancellation removes unpublished staging. A killed process leaves a private leased workspace which the next export or `oswindctl backup cleanup --directory /export/parent` can reclaim after verifying that its owner is gone. Completed exports are never cleanup targets.

## Verification

```bash
swift test --filter 'MarkdownExportTests|MarkdownTransferTests|LibraryBackupTests'
swift test --sanitize=thread --filter 'MarkdownExportTests|MarkdownTransferTests|LibraryBackupTests'
scripts/build-app.sh release
python3 scripts/markdown-export-smoke.py dist/OSwind.app/Contents/MacOS/oswindctl --interruptions
python3 scripts/markdown-export-benchmark.py dist/OSwind.app/Contents/MacOS/oswindctl --count 20000 --output /absolute/path/to/report.json
```

The process fixture uses only generated replay pixels and authored text. It checks every generated relative link, retained-media byte identity, exclusions and dependent turns, text-only default, output preservation, permissions, actual SIGINT/SIGKILL and abandoned-workspace cleanup. Unit tests include a 1,005-turn conversation, concurrent live edits against a stable snapshot, cancellation, unsafe IDs and symlink replacement after admission. A final native run on `78962ae` exercised the save panel, visible progress/disabled transfers, Cancel with no published folder, and successful completion of 20,004 sources and eight media files. All 40,016 relative links and eight media byte identities passed a subsequent file audit. A nested SwiftUI observation bug found on `dffc180` was fixed before this run. Full keyboard/save-panel failure coverage and actual Obsidian interaction remain open. [Native screenshot](../assets/markdown-export-native.png) and [scoped evidence with retained memory failure](../benchmarks/markdown-export-v1.json).

The first 20,000-source prototype peaked at 2.04 GiB. Per-record/turn autorelease pools and skipping an unused CLI embedding-model load reduced the measured peak to 107 MiB, with all 20,000 record identities retained. The corrected run took 15.5 seconds. This is one generated English-text run on M5 Max / macOS 26.6.2 with uncontrolled caches and concurrent activity; it does not establish constant memory, realistic media performance, power use or a competitor win.
