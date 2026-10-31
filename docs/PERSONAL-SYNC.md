# Personal device sync

In development. F059 remains TODO until a user can pair devices and synchronize the complete supported library. The protocol below is a foundation, not delivered sync or a replacement for the existing complete backup/restore feature.

## Delivery requirements

| Requirement | Implementation / acceptance gate |
| --- | --- |
| Offline bidirectional changes | Journal each committed mutation in the same SQLite transaction; survive process death; resume without scanning the complete archive for each edit. |
| Original evidence and user state | Sources/media, conversations/citations, recaps, recipes/run history, curated entities, aliases, links, corrections and persistent evidence pins. Validate every typed adapter; no raw peer SQL or live SQLite/WAL file copying. |
| Privacy deletion | Durable per-object deletion barriers; late/offline updates cannot resurrect that object. Intentional restoration creates a new object lifetime and preserves explicit provenance. Scoped erasure and whole-library wipe need durable collection barriers too. |
| Concurrent edits | Retain all concurrent content versions, choose a stable projection and show unresolved conflicts. A projection is not silent conflict resolution. |
| Encrypted transport | CryptoKit AES-GCM with per-context HKDF keys and authenticated group/epoch/purpose/address. Opaque keyed addresses; bounded independently encrypted chunks for large content. Never serialize group keys in settings or metadata. |
| Device trust and replay | Explicit enrollment, durable sequence/frontier checkpoints, cloned-device/fork refusal, key rotation/revocation, out-of-order delivery and rollback tests. A storage provider can withhold data; authentication alone cannot prove global freshness. |
| Device-local state | Permissions, capture activation, local model paths, provider keys, API credentials and scheduling activation stay local. Derived indexes rebuild locally. Peer privacy-check claims cannot impersonate a locally executed check. |
| User workflow | Native setup/pairing/key recovery, status/progress/pause, conflict review and revocation; CLI with secrets through bounded stdin, never argv/environment. No paid backend or account creation required. |
| Performance | Incremental bounded work, low idle overhead, cancellation, storage pressure, large replay assets and 1m-source checks. Local two-process qualification precedes actual two-Mac acceptance. |

## First implementation layer

Internal causal registers use canonical byte-derived object identities, bounded vector clocks, immutable content references and durable deletion clocks. Raw SQLite string IDs are hashed as bytes so different Unicode encodings do not silently alias through Swift String equality. A writer must extend its own prior causal state; reused live revision identities with different content are refused. Concurrent values remain available. Restoration of a deleted object uses a fresh lifetime rather than clearing its old barrier.

The encryption layer uses CryptoKit's authenticated encryption and key derivation; it does not implement cryptographic primitives. The packet address is keyed and the expected address participates in authentication. Group, epoch and purpose are supplied from local trusted context, not accepted from an untrusted packet. The outer envelope contains only a format/version and sealed bytes. Old-epoch replay, purpose/address substitution, wrong keys, tampering and oversize input must refuse before data reaches a library adapter.

## Current implementation and remaining work

The internal SQLite journal now commits its metadata, outbox/cursors and a typed caller's source mutation in the same transaction. Failed admission rolls back all of them; nested library transactions can roll back released inner savepoints. Membership is explicit, durable receipts refuse reused sequences, reordered packets persist until predecessors/content arrive, and deletion barriers apply before an older missing body can be reintroduced. Each writing connection must explicitly prepare SQLite FULL synchronization. Workspace identity and monotonic cursor checks refuse stale or corrupted writer state. Concurrent edits require explicit resolution against the exact reviewed heads.

The [portable typed codec/exporter](SYNC-PORTABLE-RECORDS.md) now represents all 13 canonical tables with immutable dependency versions and explicit local projections. This is not the complete capture-to-journal processor or typed incoming admission layer.

The [durable version catalog](SYNC-VERSION-STORE.md) is component qualified: exact typed bytes, checked local projections, original session/run metadata, historical recipe references, erasure hooks and bounded preparation. Its [receipt](../benchmarks/sync-version-store-v1.json) passes 1,483 full cases / ten skips, selected sanitizer/optimized checks and staged package/process checks, including real own-child commit recovery. The complete automatic processor, typed graph/media admission, portable provenance restore and enrollment remain open.

The [cross-object causal frontier](SYNC-CAUSALITY.md) also carries applied peer observations into new object writes and conflict resolutions. Durable early-deletion observations survive restart and migrate from the bounded pending queue, preserving body-free privacy barriers. This fixes dependency ordering; full typed graph/media admission remains unfinished.

The encrypted folder transport stores only keyed opaque names and bounded authenticated objects. Content is chunked; immutable operations publish only after complete content is present. Staging files are flushed before an exclusive atomic link publishes the final name, so a failed or racing writer cannot overwrite another operation. Wrong keys/epochs, corruption, symlinks and root replacement refuse. The transport supports explicit close and starts no listener or watcher. Actual cloud/file-provider semantics and two-Mac behavior remain unqualified; encrypted storage still reveals object counts, lengths and timing.

Forty-six focused development cases pass. The integration fixture uses two separate owned MemoryStores on one Mac and a local encrypted folder: notes flow both ways, keyword search sees the reviewed conflict resolution, and an offline edit/old packet cannot resurrect a deleted note. This fixture uses explicit note-only callbacks; it does not prove complete library synchronization, media erasure, semantic reindexing or current-policy egress protection. A seeded causal test covers 24 authored histories with 120 revisions each, four delivery permutations per history plus duplicate deliveries. Concurrent filesystem publishers and two SQLite connections are exercised too. Two intermediate test compilation failures (seeded fixture and new crash fixture) are retained. Two parent tests kill only their owned subprocess, before and after commit, and independently reopen the library to verify source/register/outbox/cursor rollback or persistence. The worker entry point skips outside that subprocess: 47 defined cases, 46 passes and one explicit worker skip. This tests process death, not physical power failure.

The first frozen broad run at fcf5d3f passes 1,351 full tests with two skips. Its sanitizer stage passes 163, skips the worker entry point and fails both crash-parent tests because the minimal child launcher omits early sanitizer loading. The child log identifies the runtime-interceptor startup error before either crash gate; no ThreadSanitizer race warning is emitted. The launcher now starts the existing xctest host directly and preloads only the sanitizer runtime already loaded by that host. Both crash-parent tests pass under TSan in development, with the worker-only skip. The original partial run is retained; corrected-source qualification is recorded below.

The [object-lifetime catalog and bounded identity bootstrap](SYNC-OBJECT-IDENTITY.md) are now in development across all 13 canonical tables. Focused sanitizer checks pass, including a retained/fixed SQLite-affinity collision counterexample. This does not complete typed body/media processing, source-version citations or user enrollment. Frozen component qualification, including the subsequent journal ordering fix, is recorded in [SYNC-CAUSALITY.md](SYNC-CAUSALITY.md).

## Corrected frozen qualification

[Source 57c1926 receipt](../benchmarks/personal-sync-foundation-v1.json), PR #93, retains all nine passing stages over 631 unchanged inputs:

| Check | Result |
| --- | --- |
| Full suite | 1,353 defined; 1,351 pass; two skips; zero failures |
| Thread Sanitizer selection | 166 defined; 165 pass; worker-only skip; zero failures/race warnings |
| Optimized selection | 166 defined; 165 pass; worker-only skip; zero failures |
| New sync cases in each build | 47 defined; 46 pass; worker-only skip |
| Staged package and processes | Strict signatures, exact extracted ZIP/tree/payload equality, normal and indexed HTTP/MCP, offline SDK and original-source privacy checks pass |
| Independent review | All frozen/log/trace hashes match; all 11 traced native images are absent; installed 15-file app is unchanged |

The two full-suite skips are the explicit opt-in system-audio fixture and subprocess worker. Process-death parents execute in all three builds; no crash gate is skipped under TSan. The original partial run and both intermediate compilation failures remain retained. Exact-source CI benchmark checks pass; its native job is still running at publication review. This qualification covers the internal foundation and inherited regressions, not the complete sync feature or distribution acceptance.

- [x] Bounded causal registers, conflict retention, deletion barriers and canonical byte identities.
- [x] CryptoKit envelopes, context-separated keys/addresses, tamper/size controls and redacted key descriptions.
- [x] Internal journal, transactional callbacks, restart, gap/dependency handling and sequence/scope fences.
- [x] Local immutable encrypted folder and chunk transport; same-host two-library note/projection/conflict/deletion fixture.
- [x] Disabled schema25 same-transaction canonical local intent capture, connection/old-writer fences and authored scale/process qualification. See [capture receipt](../benchmarks/sync-change-capture-v1.json).
- [ ] Complete automatic capture-to-protocol processing. [Schema25 canonical capture](SYNC-CHANGE-CAPTURE.md) now installs disabled local intent hooks for all 13 tables and fences older writers; the full typed processor, initial bootstrap and public enablement remain unfinished.
- [ ] All typed graph/media adapters, persistent source-version/citation identity, current-policy egress and local scan provenance.
- [ ] Scoped erasure, whole-library wipe/epoch barriers, deletion announcements, acknowledgement-based compaction and encrypted-cache retention.
- [ ] Trusted initial bootstrap, Keychain enrollment/recovery, membership/revocation and rollback checkpoints.
- [ ] Native/CLI workflows, scheduler/lifecycle cancellation, background status and conflict review.
- [x] Frozen full/TSan/optimized, owned process-crash, staged package/process qualification.
- [ ] End-to-end sync/replay scale, real providers and actual two-Mac acceptance.

F059 remains TODO. No public Sync control, cloud transfer, device enrollment or watcher is enabled by these internal components. Ordinary opening upgrades the library to schema25 and installs capture hooks; capture remains disabled. The complete feature remains the delivery target.

## Primary references

- [Apple AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm) and [HKDF](https://developer.apple.com/documentation/cryptokit/hkdf); SDK interfaces are also checked locally when web Markdown is unavailable.
- [SQLite trigger semantics](https://sqlite.org/lang_createtrigger.html): durable non-TEMP triggers are needed for cross-connection mutation coverage. Install-time validation must verify actual columns because unknown UPDATE OF columns are silently ignored by SQLite.
