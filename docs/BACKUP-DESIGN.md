# Complete library backup and restore

Status: implementation in progress on `codex/full-backup`. PR #11 is green. Database snapshot and descriptor-based file primitives with focused tests exist; no complete backup/restore workflow is delivered yet. JSON import/export remains available and is not a full backup.

## Required result

A portable local backup must preserve the database (sources, notes, metadata, vectors, passage anchors and saved chats), retained screenshots/audio and settings. It must tolerate capture and deletion on other connections, avoid loading a whole archive into RAM, report actual progress/cancellation, validate corruption and untrusted paths, and publish only a complete package. Restore must preserve the original library until a separately verified replacement is ready. API keys, the local API bearer token, model weights and disposable search caches are excluded. Restored capture/audio/API services start disabled.

Encryption and an in-app vault remain requirements for the broader parity goal. The initial package must clearly identify its plaintext contents and restrictive local permissions; a plaintext package is not an encrypted vault. Do not silently substitute a weak password scheme to close that gate.

## Database snapshot foundation

`SQLiteSnapshot.copy` uses a dedicated read-only connection with a pinned read transaction, then incrementally copies pages to a new destination. Source writes use independent WAL connections. It checks cancellation between batches, bounds busy retries, closes the backup handle on every path, verifies the result and removes incomplete destination/journal files. It rejects missing/invalid sources, final-component symlinks and existing destinations. Canonical ancestor paths accommodate macOS's `/var` alias.

The [SQLite backup API](https://www.sqlite.org/c3ref/backup_finish.html) documents incremental copies, source/destination connection separation, locking, automatic restarts and cleanup. The [online-backup guide](https://www.sqlite.org/backup.html) explains why copying a live main database file alone is insufficient. Tests must prove behavior against the actual system SQLite, not infer it from the API name.

Six snapshot fixtures cover an uncheckpointed WAL plus vectors/chats, concurrent insertion/deletion while copying one page at a time, cancellation cleanup, existing destinations, symlinks, malformed/missing databases and invalid batch sizes. Full package tests must add media and restore boundaries below.

## Media consistency without a whole-export capture pause

1. Privately pre-pin currently referenced media on the source filesystem, using descriptor-based APFS COW clones with a streaming-copy fallback. Stream the source payload rows; do not accumulate every Memory in an array. Pin by safe logical path and file identity, not by following arbitrary filesystem links.
2. Produce the database snapshot. Enumerate its referenced media and fill any pins for newly captured assets. Already pinned files survive a subsequent source deletion or overwrite. If a referenced asset disappeared before it was pinned, retry the database snapshot (bounded attempts), rather than publish an inconsistent backup.
3. Copy only assets referenced by the successful snapshot into an unpublished package beside the destination. Stream bytes and hashes, verify regular file identity/size/timestamps before and after copying, and fail on mutation or unreadable media. Never silently omit a retained asset.
4. Exclude private pin staging from normal library storage-budget traversal; clones otherwise appear to double the logical media size and could provoke unintended pruning. Staging ownership, active-job leases and conservative stale-job cleanup require tests. Cancellation removes owned staging only. Crashes may leave private staging, but must never publish an incomplete package or damage the source.

The installed SDK declares `fclonefileat` (macOS 10.12+), also listed in Apple’s [APFS API guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/ToolsandAPIs/ToolsandAPIs.html). Pins clone the already-verified descriptor rather than resolve the source pathname again. A regular streaming-copy fallback is tested; non-APFS/external-volume integration remains open.

Capture currently generates unique immutable media paths. A backup cannot promise an arbitrary cross-filesystem instant for externally modified files; that limitation must remain explicit. Test actual source deletion/new captures at each phase and retry exhaustion under sustained churn.

## Package and manifest

Use a private directory package (`.oswindbackup`) with a versioned small header, one standalone database, normalized settings and a streaming NDJSON media manifest. Each media entry maps its original logical path to an opaque lowercase-hex blob name, plus byte count and SHA-256. Opaque members avoid case/Unicode alias collisions on common Mac volumes. Original paths are metadata, never paths used to open archive members. Hashes detect corruption, not authorship/authenticity.

Manifest parsing must bound line/header/path lengths and counts, reject duplicate mappings and invalid sizes/hashes, and handle integer overflow. Only known member names and regular files are allowed. Open every filesystem component relative to retained directory descriptors with no symlink following; reject traversal, NULs, absolute paths, special files and archive/source/destination overlap. Check cancellation and disk errors while streaming. Publish the completed package atomically without replacing an existing path. Keep a partial package invisible to ordinary restore selection.

Settings restore disables capture-on-launch, microphone/system audio, API service and remote-model opt-in. API bearer tokens and Keychain secrets are recreated/configured independently; copying settings is not account authorization. Model weights and search graphs can be prepared after restoration.

## Restore into a new verified library

Initial restore creates a new library directory and leaves the current library intact. It must be a usable library, not merely an extracted collection of files. The UI needs a deliberate way to select/open it after verification, along with startup recovery if a chosen external library is unavailable. CLI restore must route before ordinary MemoryStore creation so a failed validation cannot create/migrate a target by accident.

A chosen archive is untrusted input. Do not open its database as a normal MemoryStore and execute archived triggers. Reconstruct into the current compiled schema, copying data from known tables/columns with bounded payload validation. Validate source metadata against its payload, remap asset references to safe new paths, preserve source/chat identifiers and supported vectors/passages, and derive new registry/statistics/cache identity. Do not import arbitrary views, triggers, indexes or store control metadata from the archive. Preserve privacy settings and recorded scope/timezone fields. Check foreign keys, source counts, required asset references and integrity before atomic publication.

In-place replacement while other processes retain old database handles can corrupt media after a folder swap. A new-root restore avoids that race. Future in-place/undo support needs a process-wide lifetime lease protocol and crash-recovery state, with older already-running writers addressed explicitly; a successful rename alone does not prove safety.

## Remaining implementation and evidence

- Descriptor-based filesystem primitives pass 13 focused fixtures, including a successful APFS clone and forced streaming fallback. Package manifest work remains.
- Streaming source pre-pin, snapshot/retry, copy/hash/progress/cancel and stale-stage cleanup.
- Complete archive inspection and safe data-only reconstruction with old-format adapters.
- UI/CLI backup, inspect, restore and library selection/relaunch/recovery.
- Tests: WAL/chats/media/vectors/passages round trip; concurrent capture/deletion; schema/manifest tampering; malicious triggers; path/symlink/case aliases; oversized/truncated data; destination refusal; interruption/disk failure; no credentials or service auto-start.
- Performance: sustained capture/search during backup, large archive RSS/disk/index lag, cancel latency, cold restore and controlled filesystem conditions. Retain failures and raw trials. Do not count a database-only fixture as full media/restore validation.
- Encryption/vault and native GUI acceptance remain separate delivery gates.
