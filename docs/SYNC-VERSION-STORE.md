# Durable sync versions and local bindings

Component qualified, with full sync still in development. This is a required part of [complete personal sync](PERSONAL-SYNC.md), which remains unfinished. Ordinary library opening does not install this catalog, activate capture, enable sync or expose a listener. Schema25 remains unchanged.

## What is retained

The internal `SyncVersionStore` stores canonical typed record bytes under their global object lifetime and immutable content hash. It uses the same SQLite connection as the identity catalog and causal journal. Group, epoch, capture origin/generation, durability flags and protection schema must match. The owning library serializes access to that borrowed connection.

New content must be an admitted journal head or the exact immutable dependency requested by an authenticated head/already-retained record. An object-only dependency cannot authorize an arbitrary historical version. The local owner must still be mapped, live and unrevoked. Every body read and retention requires a current-policy admission callback. Authentication, current privacy, complete graph/media adoption and transport orchestration remain caller responsibilities.

Exact lookup never falls back to a newer body. A separate projection pointer identifies the explicitly bound local version. Binding rebuilds the portable record from the actual canonical row and requires byte equality; dependency versions, source passages and kinds are checked too. Current lookup verifies the original canonical-row digest again. SQL IDs, local evidence hashes, entity revision hashes and wire content hashes remain separate domains.

Two retained counterexamples demonstrate why admission is checked again before returning. The first implementation's duplicate path could commit an epoch change made during admission. A same-transaction erasure callback could also remove the source/cache while a read returned its previously loaded body. Both now refuse and roll back; the tests check that the actual erasure boundary was reached. An earlier test that stopped at an unsupported nested public transaction is explicitly excluded as proof of that boundary.

Three further corruption cases initially retargeted an old source domain, recipe revision or run ordinal without changing canonical rows. Source lookup now derives both revision domains from the actual original Memory. Recipe/run binding checksums detect changed metadata, including blob writes below immutable SQL UPDATE triggers. These are corruption checks, not a claim of protection against an attacker who can rewrite all local state and hashes.

## Audio sessions and recipe history

- Audio session tokens retain their original namespace independently of cached source bodies. A source update can invalidate its old bodies while preserving the token needed to re-export an unchanged peer session. Session changes, primary-key moves and deletion clear that binding. A projection-shaped session without its original binding refuses rehashing. Metadata lookup applies current source policy.
- Prepared recipe definitions bind native revision numbers to immutable content references. Known references survive a missing cached body; missing content stays unavailable. Pre-enrollment definitions that were never retained remain explicitly unknown and cannot substitute the current definition.
- Each prepared run retains its original recipe editor, ordinal and definition reference. These can differ from the local SQL revision number. Status changes and restart preserve the original attribution. The exporter consults that explicit binding before its local-revision fallback; conflicting attribution refuses.

The local bindings do not carry provider keys, endpoints, execution activation or model paths. Received recipes remain data and do not confer authority to run AI or scheduled work.

## Erasure, limits and schema checking

Installed canonical-delete and primary-key-move triggers immediately clear owned cached bodies/projections and add opaque lifetime revocations. They also clear audio/run/recipe bindings. Source-content changes invalidate old bodies; favorite/tag metadata can retain immutable versions, while current projection lookup requires revalidation. Existing canonical cascades remove cached dependent answers, recaps and conversation labels. These protections operate before a later capture processor consumes the deletion intent.

Recipe definitions deliberately retain history across ordinary recipe edits and clear on recipe deletion. Full wipe removes bodies and local bindings. SQL deletion is distinct from physical page reclamation; the existing wipe/compaction workflow remains relevant. Full collection epochs, remote erasure propagation and tombstone compaction remain unfinished.

The default logical cache budget is 256 MiB, configurable internally up to 8 GiB. Accounting includes record bodies plus fixed bookkeeping and recipe/session/run metadata. A full cache refuses preparation transactionally without advancing the journal. Idempotent binding succeeds at the limit. This is a logical cache bound, not total SQLite-page, outbox, journal, memory or retained privacy-barrier size.

Protection schema definitions are checked at installation and whenever SQLite's schema cookie changes. A connection-local locked stamp avoids repeating every schema query for every record. Data identity, epoch, capture scope, policy and content checks still execute for each operation. Missing or changed protection triggers refuse; installation does not silently repair them or relabel existing state.

## Current evidence and remaining work

Development passes 111 selected cases / one worker-entry skip, including 33 new version-store cases and all four new process-death parents. Actual rows from all 13 canonical tables survive restart with original source frames unchanged. Exact-version refusal, policy callbacks, journal rollback, budgets, Unicode IDs, erasure cascades, full wipe, blob corruption, missing protection triggers, forged accounting, recipe/session history and a second connection are exercised. Initial compilation, fixture failures and pre-fix admission/binding failures remain retained.

The first bounded scale observation, before the recipe/session additions, prepares 1k/10k authored notes in 5.63/53.22 seconds. With those additions and full repeated schema checking, preparation takes 7.43/69.36 seconds. Schema caching then gives 2.84/28.20 seconds in development and 2.95/28.98 seconds on the final frozen source. All original source bytes agree; independent readers validate all typed packets, projections, journal/registers and timing summaries. These are single warm component runs; metadata integrity/column-invalidation checks also changed between snapshots. They do not isolate hardware/thermal effects or establish model/media/transport/energy throughput.

The [frozen receipt](../benchmarks/sync-version-store-v1.json) passes all 15 stages over 845 unchanged inputs: 1,483 full passes / ten explicit skips, plus 304 sanitizer and 304 optimized passes / five skips each. All 33 version cases and all four process-death parents execute in every build, with no race warnings. The selected skip list includes four worker entry points and the separate opt-in Metal expression fixture; that GPU fixture passes in the full opt-in suite. All 15 historical input versions and the actual retained optimized benchmark bundles are verified. Earlier failures remain retained.

Staged capture/conversation/recap/deletion/wipe/backup/interruption, normal/indexed HTTP/MCP and offline SDK checks pass. Independent strict signatures, normalized payloads and all 34 extracted ZIP files agree. All five traced owned images are absent; the installed 15-file app remains unchanged. Three retained authored indexed graphs independently preserve full membership and all five exact result scopes. These are component/staged-package checks, not native release or notarized distribution acceptance.

The local backup test preserves canonical data while restoring quietly without copying old sync authority or caches. Complete portable provenance rehydration after restore remains integration work; this test does not prove that device-local session/recipe bindings survive migration or re-enrollment.

- [x] Durable typed bytes, exact dependency lookup and explicit local projection.
- [x] Post-admission epoch/liveness checks, original session/run metadata and logical cache accounting.
- [x] Functional checks across all canonical tables and public local erasure/wipe paths.
- [x] Independent source/body/journal/timing review and bounded optimized scale observations; six reader admission/corruption contracts.
- [x] Selected sanitizer/optimized checks and four real process-death parents.
- [x] Full regression and staged package qualification, with signatures, extracted ZIP equality and installed-app preservation independently checked.
- [ ] Complete automatic capture/bootstrap-to-journal processing and all typed incoming graph/media adapters.
- [ ] Current privacy/erasure epochs, portable provenance restore/migration, cache/backpressure workflow, trusted enrollment, native/CLI controls and provider/two-Mac acceptance.

F059 and all 78 delivery requirement statuses remain unchanged. These components do not establish feature-complete parity, physical power performance or a competitor ranking.
