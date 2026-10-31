# Bounded outgoing sync processing

Internal component qualified, 2026-10-31. F059 remains TODO: enrollment, incoming processing and complete supported-library sync are not delivered by this layer.

`SyncOutgoingProcessor.step` automatically chooses one bounded transaction:

1. Assign pending capture lifetimes and replace raw intents with durable outgoing work.
2. If raw capture is empty, prepare staged typed objects and their dependencies, retain exact versions, bind actual local projections, write the causal journal and acknowledge work together.
3. If neither queue has work, advance a durable bootstrap cursor for one of the 13 canonical tables. Later calls process those objects through the same typed path.
4. Return idle after every table completes. A later canonical mutation resumes capture processing; idle does not mean uploaded or received by another device.

This closes the ordering gap between bounded identity batches and cross-object export. A dependency outside the current bootstrap batch can acquire its identity only after all raw capture lifetimes drain. Later bootstrap reuses that identity. Deletion/recreation and primary-key moves preserve distinct lifetimes; no dependency is minted through an older unprocessed deletion.

## Work and transaction boundaries

`SyncOutgoingWorkQueue` stores an ordinal, opaque object digest, deletion flag and last local capture sequence. It stores no body, raw primary key, media path or credential. Repeated changes coalesce within a lifetime; deletion is terminal for that lifetime. Source erasure still uses the version catalog's immediate canonical hooks. A new lifetime at the same local key has separate work.

Raw acknowledgement and staging commit together. Typed journal/cache/projection output and work acknowledgement commit together. Failure, cancellation, policy refusal or new capture generated during admission rolls back the current transaction. Nested processor entry refuses. Explicit same-connection ownership, active capture, generation, FULL synchronization, recursive triggers, foreign keys and exact work schema are checked.

The default logical work budget is 64 MiB, charged at 192 bytes per distinct pending lifetime, with an explicit resize API up to 8 GiB. This excludes physical SQLite pages and the separate capture, version-cache, journal and transport budgets. A full queue preserves the unacknowledged raw intent; it does not drop work. Large offline backlogs may require raising this budget before every raw lifetime can drain. The user-facing backpressure workflow remains unfinished.

Both catalog peer writes and direct echo suppression now refuse while identified local work remains. Draining raw capture alone cannot let a peer overwrite unprocessed local intent.

## Typed graph admission

The processor exports actual canonical rows from all 13 tables, including recaps, conversations/citations, entities/corrections/pins, recipes and runs. Dependency preparation is bounded by object count, typed bytes and recursion depth; defaults are 512 objects, 16 MiB and depth 32 per transaction. Oversized, cyclic or unavailable exact dependencies refuse without acknowledging the work. These bounds have explicit internal configuration; large graph scheduling and its user-facing recovery remain integration work.

Current local-row and typed-version admission callbacks are required. The owning service must provide the complete production privacy/epoch admission; the component tests exercise those callback boundaries with authored data. A required media callback must supply every declared asset manifest. Missing media refuses; file staging, verification, encryption and transfer are not implemented here.

Existing exact versions can satisfy immutable references. Current source evidence/entity domains remain distinct from wire hashes. Original session tokens and per-run recipe bindings use the durable catalog. Known historical recipe definitions remain original after later definition/status edits; pre-enrollment unavailable history stays explicitly unavailable. Concurrent register heads require explicit conflict resolution and are not silently overwritten. Matching single heads are reused without duplicate journal operations.

Ordinary opening remains schema25/capture-disabled. It installs neither this queue nor the processor, and starts no scheduler, watcher, transfer, model or listener. The owning library must serialize the borrowed connection. Quiet restore preserves canonical data without cloning pending work or replica authority; portable session/recipe provenance rehydration after migration remains unfinished.

## Evidence and remaining delivery work

The [receipt](../benchmarks/sync-outgoing-processor-v1.json) independently verifies all 16 stages over 853 unchanged inputs: 1,515 full passes / 12 explicit skips; sanitizer and optimized selections each pass 336 / seven skips with zero race warnings. All 26 outgoing cases and six real own-child crash parents execute in every build. The worker-only crash entry and opt-in outgoing scale case skip normally. The separate opt-in Metal expression fixture executes in the full run.

The six crash parents kill only a nonce-owned child immediately before/after staging, bootstrap or typed commit, reopen the actual database and finish the real processor without duplicate output. This is process-death recovery, not physical power-failure evidence. Preexisting and captured actual graphs cover every canonical table in single-row batches; original canonical frames remain unchanged. Restart, rollback, source deletion cascades, Unicode keys, historical recipe bindings, current-policy/epoch reentrancy, budgets, corruption/cycles and cross-connection peer fencing are exercised.

Staged capture/chat/recap/deletion/wipe/backup/interruption, HTTP/MCP and offline SDK checks pass. Independent review verifies strict signatures, normalized executable payloads, all 34 extracted archive files, three authored indexed graphs and absence of all five traced images. The installed 15-file app is unchanged. Additional packaged-CLI terminal runs pass real Ctrl-C create/unlock/lock and the deliberate held-reader refusal, normal recovery and original-history checks; all their owned images are absent.

One initial media fixture failed canonical insertion before reaching outgoing admission. Two sanitizer attempts retain ANN diagnostic setup refusals (missing parent, then missing ownership marker); another runner setup failed before any test. The corrected run uses the existing ownership setup tool and verifies its marker as a frozen input. These failures remain retained alongside the passing qualification.

The parent [PR #100 hosted run](https://github.com/vibhusapra/OSwind/actions/runs/41185203985) fails an ordinary terminal lock with `hdiutil exit 16`. Its earlier unit/native-vault/package stages pass; later process stages skip. The local terminal passes above do not establish that failure's cause or resolve it.

| Authored warm bootstrap | Observed duration |
| --- | ---: |
| 1,000 notes | 4.68 s |
| 10,000 notes | 46.58 s |

One optimized run per size, batches of 128. Timers include automatic bootstrap/work staging, dependency identity checks, canonical reads, typed export, journal/cache/projection writes, work acknowledgement and completion of all 13 bootstrap cursors. Raw SQL population, setup, source checks, privacy inference, models, media and transport are excluded. This is a different scope from the earlier version-store-only measurement; no isolated speedup or competitor comparison is inferred.

The independent reader checks every original cell/payload, identity, typed packet, projection, journal/register, accounting, cursor and timing summary across all 11,000 notes. All eight marker/admission, in-place corruption, pending-work, cursor and step-membership refusal checks pass; original SQLite files remain unchanged. Reproduce with `OSWIND_TEST_SYNC_OUTGOING_SCALE_OUTPUT=/fresh/absolute/private/path swift test -c release --filter SyncOutgoingScaleTests`, then `python3 scripts/review-sync-version-scale.py /fresh/absolute/private/path --outgoing`.

- [x] Bounded automatic outgoing bootstrap/capture-to-work-to-typed-journal processing across all canonical tables.
- [x] Durable staging, peer-write fencing, graph bounds, history/conflict semantics and real process-crash recovery.
- [x] Full/sanitizer/optimized, independent scale, package and process qualification.
- [ ] Complete incoming typed graph and exact-version citation materialization, projection collisions and conflict workflows.
- [ ] Media staging/verification/transport, production privacy admission and erasure/wipe epochs, compaction and provenance restore.
- [ ] Trusted enrollment/Keychain/rotation/revocation, native/CLI service lifecycle, status/backpressure controls and provider/two-Mac acceptance.
- [ ] Diagnose the hosted terminal-lock failure; physical power, unattended capture, notarized distribution and whole-product parity/ranking acceptance.

All 78 feature statuses remain unchanged. This component does not establish feature-complete sync or a competitive ranking.
