# Sync object lifetimes and bootstrap

Work in progress. This internal layer maps the 13 captured canonical tables to global object lifetimes and provides resumable identity bootstrap. It does not enable sync, enroll a device, transfer a complete library or replace typed privacy admission. F059 remains TODO; the complete delivery requirements remain in [PERSONAL-SYNC.md](PERSONAL-SYNC.md).

## Identity and local changes

An object identity contains a canonical table, origin UUID and lifetime UUID. Its protocol key hashes their framed bytes with the object-kind domain. Local primary keys stay separate: the catalog indexes the same complete byte-framed SHA256 key as the capture triggers. NUL and distinct Unicode encodings do not alias through Swift String equality. Text IDs and integer citation ordinals require their exact storage classes before hashing or SQL lookup; SQLite affinity cannot create another identity for an equivalent key. Chat and recap citation rows have their own internal protocol kinds.

Updates keep the current lifetime, including local edits to a source received from another device. A primary-key move retires the old lifetime and creates a new one. Deletion/recreation under the same local ID creates a fresh lifetime; historical tombstones remain addressable. Deleted catalog rows clear their raw primary-key frame. The mapping retains opaque key digests, not old source bodies. This does not establish forensic erasure or resistance to guessing low-entropy local keys.

`process` reads actual captured intents in sequence, including superseded metadata needed to distinguish lifetimes. It verifies a live row frame's primary key before mapping it. The required consumer commits its typed journal/cache output in the same transaction as identity changes and queue acknowledgement. Failure, cancellation or an outer rollback preserves the prior queue, catalog and caller writes. A nested processor is refused. A required callback alone does not prove typed processing: production still needs the complete processor below.

## Peer admission

The peer adapter and catalog mapping commit together with echo suppression. A different live object cannot take an occupied local key; one global object cannot silently move to a different local key. A deleted lifetime cannot be admitted as a live object. A deletion for an old lifetime does not select the replacement occupying its former key. Source existence/deletion is checked before committing the adapter result.

A wire delete has no content body and may arrive before any source metadata. `deletePeerKey` therefore requires the deletion barrier already installed in the same-connection journal. Unknown keys need no invented origin/lifetime. The journal suppresses a later missing put before requesting its body. A new lifetime has a distinct key and remains eligible for normal admission. Complete typed consumers must validate that their decoded identity matches the authenticated revision key.

## Bounded bootstrap

Bootstrap reads canonical primary keys with binary keyset ordering, rather than OFFSET or a full archive-wide key hash scan. Calls are limited to 512 objects and an explicit key-byte budget (default 1 MiB, maximum 8 MiB). The keyset SELECT returns at most its requested count plus one key; each call assigns/reuses identities, calls its typed consumer and commits a durable cursor in one transaction. A caller prepares and validates the complete current source content inside that transaction before publishing protocol output.

Local intents must drain before a bootstrap batch. A newly inserted key behind the cursor remains in capture, so it cannot be skipped by a later keyset query. Source updates after a batch also remain in capture. Completed tables return immediately; new mutations use the feed. A cursor whose object is deleted is cleared when that deletion is processed, restarting the table scan without retaining the deleted raw key. Deletion of the cursor row inside the consumer is checked before saving it too. A restarted scan may revisit previously assigned identities; the eventual typed processor must avoid needless duplicate revisions. Completed cursors retain no raw key.

Exact catalog SQL definitions, scope/generation, current mappings, FULL/recursive preparation and foreign-key enforcement are checked. Partial or changed catalogs refuse instead of being silently recreated. These checks detect specific invalid state; they are not cryptographic attestation against arbitrary local-database tampering.

The four catalog tables are installed only by an explicit internal call. Ordinary MemoryStore opening still uses schema25 and leaves capture disabled. No public pairing, bootstrap runner, watcher or user enablement is introduced.

## Development evidence

- The initial selection passes 85 cases with one subprocess-worker skip, including 15 new identity cases and real captured structural rows from every canonical table.
- Schema/foreign-key hardening and real unknown-wire-delete/journal integration expand it to 88 passes with one worker skip.
- Bounded bootstrap expands it to 94 passes with one worker skip, including all 24 new cases. Reopen/resume, raw Unicode/NUL ordering, byte budgets, failed consumers, cursor deletion and new keys behind the cursor pass.
- Expanded composite text/integer pagination initially fails compilation because its count assertion compares Int with Int64; no tests execute. The corrected sanitizer selection passes all 94 cases with one worker skip and zero race warnings.
- A separately executed counterexample then fails one test with three assertions: integer 1 can address text ID "1" through SQLite affinity while producing another catalog digest, admitting an overwrite. Exact per-column primary-key storage checks fix admission before the callback. The unchanged overwrite regression plus numeric-ID/text-ordinal controls pass in the expanded sanitizer selection: 96 defined, 95 passes, one worker skip, zero failures/race warnings; all 25 identity/bootstrap cases execute. The failed source, test and logs remain retained.
- The optimized selection also passes 95 cases with one worker skip; all 25 new cases execute. The [development receipt](../benchmarks/sync-object-identity-development-v1.json) retains current source/input fingerprints, every passing stage, both failures and the exact before/fixed primary-key admission code. Full/package/process regression, process-death bootstrap tests and authored scale qualification remain pending. Earlier runs remain separate.

Structural raw graph rows test local identity handling; they do not establish valid peer graph payloads. Current tests use owned temporary libraries, no normal history, provider or media capture.

## Remaining delivery work

- Qualify real pre/post-commit process death, composite pagination and authored 1k/100k/1m behavior with independent original-source/mapping/timing checks.
- Finish complete typed graph/media bodies and reference rewriting, stable source versions/citations, and the bootstrap/capture-to-protocol processor. Keep private paths, credentials, local scheduling authority and peer scan claims out of transported authority.
- Validate current privacy on outgoing and incoming content, with content revalidation after preparation outside the writer transaction.
- Finish scoped erasure/wipe epochs, priority deletion, acknowledgement-based compaction, encrypted-cache retention and storage-pressure recovery. Catalog tombstones currently grow with object lifetimes.
- Add trusted enrollment/recovery/revocation, Keychain, lifecycle scheduling, native/CLI status and conflict review; then qualify real file providers and two Macs.

The complete sync feature remains the target. This document records an implementation layer and its current evidence, not delivered sync or broad desktop parity.
