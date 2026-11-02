# Personal device sync

In development. F059 remains TODO until a user can pair devices and synchronize the complete supported library. The protocol below is a foundation, not delivered sync or a replacement for the existing complete backup/restore feature.

The current internal foundation includes [durable answer admission](SYNC-DURABLE-PUBLICATION.md), [backup erasure fencing](MEDIA-CLEANUP-ADMISSION.md) and [native33 media compatibility](NATIVE-MEDIA-COMPATIBILITY.md). The [current component receipt](../benchmarks/native-media-compatibility-v1.json) binds source `fe54050`, all88 mandatory controls in three builds,30 package/process stages and39 owned native methods. Optimized source14c has identical native/test/package/runtime bytes and a separately declared final-inspection script delta. This enables no public enrollment or synchronization service. All delivery requirements below remain the acceptance scope.

The [current prepared-session app owner](SYNC-APP-OWNER.md) connects the real service to app retirement and reversible processing suspension. It does not expose a public enrollment constructor or complete the remaining trust, recovery, erasure and provider requirements below. Historical receipts retain their original sources.

The [signed pairing/v3 transport component](SYNC-SIGNED-PAIRING.md) now supplies root-signed addition-only membership, exact capabilities, expiring recipient-bound responses and per-device authorship. The app owns asynchronous setup before it may install native state. This still enables no public enrollment: Keychain/pending-request persistence, refresh/recovery/revocation/rotation, old-writer and external rollback authority, erasure application and physical acceptance remain required.

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

Internal typed components now cover all thirteen canonical kinds, exact source/run originals, optional references, unavailable entity scopes, causal gaps, durable withheld answer work, physical stale-projection retraction and version-aware source/citation retirement. Current code keeps independent future/concurrent owner versions while honoring genuine required-source/pin barriers. Older source-bound milestones below are historical receipts; their counts and unchecked prerequisite boxes do not replace the current end-to-end gates.

Before enabling public sync:

- Integrate the owning dispatcher for the complete graph, current privacy/provenance policy, media admission and encrypted transport. No peer may provide execution authority or a locally verified scan claim.
- Deliver collection erasure/wipe epochs for unknown offline objects, durable deletion announcements and acknowledgement-based compaction. Per-object component barriers are insufficient for complete collection erasure.
- Give erasure a production strategy under queue pressure, compact terminal work, and finish encrypted orphan/quarantine/cache retention. Current explicit refusal/rollback is verified; permanent full-queue progress is unfinished.
- Complete trusted bootstrap, membership/key enrollment, recovery/rotation/revocation and rollback checkpoints. Keep secrets out of settings, argv, environment and ordinary logs.
- Add native/CLI pairing, status, pause, conflicts and lifecycle cancellation. Finish cleanup scheduling after reservations release; old cleanup binaries remain outside the new exclusive gate.
- Qualify real providers and actual two Macs, interrupted/offline replay, complete source/media identity and representative incremental/idle/large-archive behavior. Physical power and product ranking remain separate.

### Historical prerequisite checklist

The following four items record an earlier checkpoint. Later internal receipts address many of their fixtures; the service must integrate and qualify every invariant, so end-to-end acceptance remains open.

- [ ] **Late unseen dependent records:** distinguish a temporarily missing dependency from an authenticated deletion barrier. Static review shows that `SyncVersionStore.resolve` refuses an unavailable/deleted dependency and an exception from the typed writer rolls back `SyncJournal.receive`, including its receipt and cursor. Refusal preserves the current privacy boundary but does not prove forward progress for the rest of that sender's stream. Reproduce this with three owned replicas before changing behavior. A child that never existed on the receiver needs an explicit, durable outcome; do not silently acknowledge it or clear a parent barrier.
- [ ] **Deletion semantics across all thirteen kinds:** define retirement edges separately from optional scope references, matching reviewed native erasure behavior. A removed source link must not delete an independent curated entity. Test late answers/recaps, runs, aliases, mentions, corrections and pins as well as already-materialized descendants. A newer intentional restoration must use a new lifetime.
- [ ] **Liveness and atomic recovery:** follow a late dependent put with an unrelated record from the same sender and verify both the durable child outcome and later cursor progress. Include missing predecessors, an early out-of-order parent tombstone, duplicate/restarted delivery, cross-object causal clocks, second-announcement failure and owned pre/postcommit process death. Unavailable live dependencies remain retryable; malformed or unauthorized records remain refusals. Check native rows, original evidence, journals, caches and media reservations together.
- [ ] **Complete public sync:** implement collection erasure/wipe epochs and acknowledged compaction; current-policy/provenance and media admission; lifecycle and transport; Keychain pairing/recovery/revocation; status/conflict UI; and actual provider/two-Mac acceptance. These gates are additional to the typed component tests. No public sync control should imply they are complete.

[Derived child retirement](SYNC-DERIVED-RETIREMENT.md) passes twenty frozen functional stages on unchanged schema31. Common incoming puts/deletes publish barriers for actual native removals and selected source/citation lifetimes, with root causal observation, exact keys, atomic cache/mapping retirement and real process-death recovery. This closes the tested receiver-only child paths; scoped/wipe collection barriers, production admission/service, late unseen dependent records and actual two-device acceptance remain required. F059 stays TODO.

[Whole-source peer erasure](SYNC-SOURCE-ERASURE.md) passes twenty functional qualification stages on schema31, including cached citation owners, inactive lifetimes, cache-only media and actual old30 migration/refusal. All thirteen canonical kinds now have internal positive projection and tombstone paths. The child-retirement component above follows this receipt. Scoped/wipe epochs and the complete privacy/media/service workflow remain required. F059 stays TODO.

[Incoming metadata tombstones](SYNC-INCOMING-DELETIONS.md) pass twenty functional qualification stages for conversations, turns/citations, recipes/runs and pins. Entity/recap retirement paths are retained; unknown keys across all thirteen canonical kinds receive body-free barriers. Its schema30 receipt precedes the source-erasure component above. Replicated receiver-only child retirement/epochs remain required. No service is enabled.

[Incoming entity graph](SYNC-INCOMING-ENTITIES.md) passes twenty functional qualification stages on schema 30: typed entity/alias/link/correction admission, content-free entity-table deletion, scoped independent-definition preservation and indexed outgoing merge ordering. All thirteen canonical record types now have internal positive projection paths. Complete graph/deletion/policy/media/service and user enrollment remain open.

[Incoming sources and original preservation](SYNC-INCOMING-SOURCES.md) are component-qualified schema-28 work in [PR #106](https://github.com/vibhusapra/OSwind/pull/106), stacked on the qualified historical-citation and original-field erasure components. Exact source/recap/answer/pin graphs and ordinary local privacy invalidation have retained frozen evidence. [Incoming recipes and run history](SYNC-INCOMING-ROUTINES.md) are tested internal schema-29 adapters; [run-specific recovery and authored scale](SYNC-RUN-RECOVERY.md) now have frozen evidence. Complete graph/deletion/policy/media/service and two-Mac acceptance remain unfinished; F059 stays TODO.

The internal SQLite journal now commits its metadata, outbox/cursors and a typed caller's source mutation in the same transaction. Failed admission rolls back all of them; nested library transactions can roll back released inner savepoints. Membership is explicit, durable receipts refuse reused sequences, reordered packets persist until predecessors/content arrive, and deletion barriers apply before an older missing body can be reintroduced. Each writing connection must explicitly prepare SQLite FULL synchronization. Workspace identity and monotonic cursor checks refuse stale or corrupted writer state. Concurrent edits require explicit resolution against the exact reviewed heads.

The [portable typed codec/exporter](SYNC-PORTABLE-RECORDS.md) now represents all 13 canonical tables with immutable dependency versions and explicit local projections. This is not the complete capture-to-journal processor or typed incoming admission layer.

The [durable version catalog](SYNC-VERSION-STORE.md) is component qualified: exact typed bytes, checked local projections, original session/run metadata, historical recipe references, erasure hooks and bounded preparation. Its [receipt](../benchmarks/sync-version-store-v1.json) passes 1,483 full cases / ten skips, selected sanitizer/optimized checks and staged package/process checks, including real own-child commit recovery. The complete automatic processor, typed graph/media admission, portable provenance restore and enrollment remain open.

The [immutable original-evidence layer](SYNC-ORIGINAL-EVIDENCE.md) now materializes admitted exact source versions as read-only native projections, separately from current canonical memories. It is component qualified with full/TSan/optimized, real process-crash, independently checked 1k/10k scale and staged package/process evidence. Canonical incoming citation bindings/native opening and complete graph/media/service integration remain unfinished.

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
- [x] [Bounded automatic outgoing bootstrap/capture-to-work-to-typed-journal processor](SYNC-OUTGOING-PROCESSOR.md) across all 13 tables, with durable staging, dependency ordering, mandatory admission callbacks, real crash recovery and independently checked authored scale.
- [ ] Deliver the complete capture-to-protocol service: production privacy/epoch admission, media staging/transport, lifecycle/scheduling and public enablement remain unfinished. Ordinary schema25 opening stays capture-disabled.
- [x] Internal incoming source/recap/answer/pin graphs with exact cited originals.
- [x] Internal paused recipe/run projection, exact old prompts/status, quiet restore/re-export and run-specific recovery/scale.
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

[Late dependent retirement](SYNC-LATE-DEPENDENCIES.md) passes 22 local functional stages over 725 repository inputs. Known erased owning/evidence parents no longer force an endless dependency-fetch refusal for the tested late child kinds; genuine barriers and later sender progress are verified. Optional references, unseen citation visibility, early out-of-order gap acceptance, service/providers/two-Mac and representative performance remain required. F059 remains TODO.
