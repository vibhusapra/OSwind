# Incoming source projection

Component qualified on `codex/sync-incoming-sources`, based on schema 27 PR #105. The overall v0 and F059 remain incomplete. No background service, pairing or transport is enabled.

## Behavior and bounds

The typed incoming writer materializes native source text, context, times, sampled spans, transcripts, tags/favorites, explicit audio-session identity and admitted media. Storage paths, embeddings, model paths, permissions, keys and activation authority are local. The caller authenticates and receives the journal operation, reserves media before SQLite/journal locks, stages exact dependency bodies/media, and supplies current-policy record/media admission. Actual media hashes are verified before and after mutable hooks. Format admission and safe staging remain caller/service requirements.

A peer update preserves previously cited versions. Before replacement, the writer promotes referenced old native versions to archival originals and rebinds current recap/answer/pin links atomically. It keeps recap text and wire versions unchanged while updating local provenance. Ordinary local corrections retain their existing privacy invalidation behavior. Recap citation replacement follows the producer's actual delete-before-put sequence: retire the old global citation while retaining a native relationship still independently required by its complete owner, then bind the replacement under a fresh lifetime.

One connection-owned, default-deny permit covers one exact native Memory or one ordinary-to-historical citation conversion. It clears on error and is non-deterministic. It cannot approve a different owner, payload, primary key, score, passage or unrelated metadata. Schema 28 installs 42 compiled older-writer fences across all 13 canonical tables and archival rows. Current missing or altered protection is refused; exact legacy protections migrate atomically.

Promotion is bounded to 512 current source/recap nodes. Immutable dependency preparation keeps its 512-node / 32-depth bound. Indexed ordinary recap links select descendants. Each old packet must match its actual projection. A pin already bound to an older original keeps that exact version. All native/cache rebinding and source/journal mutation share one transaction.

A final callback-free audit checks up to 2,048 unique exact typed versions across the combined dependency DAG, with a 32-depth bound. Identity-only dependencies require one journal head matching their current projection; exact historical references keep their recorded versions. Source and conversation/citation/pin adapters share this audit. Final native/cache comparisons and wire-link matching use encoded bytes. Promotion maps use UTF-8 byte keys so canonically equivalent local IDs stay distinct.

## Verification

The [receipt](../benchmarks/sync-incoming-sources-v1.json) passes all 24 stages across 677 identical tracked repository inputs:

- Full default: 1,547 passed / 77 explicit skips, zero failures.
- Thread Sanitizer: 422 passed / 10 skips, zero race warnings.
- Optimized: 424 passed / eight skips, zero failures.
- Sixteen SDK cases, signed normal/indexed HTTP/MCP, original-field and ordinary erasure, deletion/retention, wipe/backup interruptions and recap processes pass.
- Actual already-initialized old25/26/27 writers and fresh clients refuse schema 28. Real schema-27 SQLite migration, readonly old27 archive inspection and quiet old27/current28 restores preserve exact originals and citations. Restored scoped erasure passes.
- All 34 extracted ZIP files and strict signatures match. The installed 15-file app stays unchanged; test fixtures are excluded.

The final independently reviewed optimized fixture receives 1,000 / 10,000 notes with 1 KiB text padding through actual outgoing packets and incoming journal/native projection, using 128-record SQLite transactions. One warm run per size takes 8.928 / 90.664 seconds. Ten cited updates preserving two recap levels and answers take 1.696 / 1.665 seconds. Hardware: Apple M5 Max, 128 GiB, macOS 26.6.2. Models, media, transport, policy inference, cold cache, physical power and competitor ranking are excluded.

The independent reader verifies actual producer packets, every receiver identity/current frame, 60 archived native projections and dependency graphs, accounting, exact citation/pin versions and original chain content. All four SQLite files stay unchanged. Eight negative controls pass, including a retargeted pin whose independent foreign keys remain valid.

A separate readonly review checks the retained final-code receiver databases after real own-child pre/postcommit SIGKILL and recovery: current text and citation direction, eight current frame/packet bindings per case, two committed archival projections/one edge versus zero before commit, exact journal heads and unchanged outgoing counts. Both receiver files stay unchanged. This is text-only crash evidence.

The raw qualification snapshots include two ignored, unused schema26 SQLite sidecars (empty WAL and shared-memory file), giving 679 raw entries. The portable manifest contains the 677 tracked files, all verified against implementation commit `0446b8a`; raw snapshot hashes and excluded sidecar hashes remain in the receipt. This metadata correction changes no implementation, fixture database, test result or package.

## Retained regressions

The development evidence keeps the naive 14-failure update, nine/ten-column binding-frame refusal, omitted delete-before-replacement fixture event, stale schema-27 backup expectation, eight-failure source ancestor admission, and 12-failure shared-adapter stale-head/ancestor admission. A non-source conversation ancestor deleted during chat-citation admission is also covered. Byte-distinct Unicode owners and wire metadata have explicit regressions.

The first scale attempt refuses close while its owned reservation remains active; the fixture now releases each phase's reservation before close. The first independent reader omits the 128-byte charge per archive edge; the corrected reader includes it. Compiler and setup attempts remain separate. All attempts retain their own source manifests and logs.

## Adapter completion checklist

- [ ] Complete replay/media-format acceptance alongside exact screen/audio/sampled projection and session/media admission.
- [x] Source replacement preserves ordinary and historical answer/recap chains and exact cached versions without echo.
- [ ] Full logical recap-link replacement/retirement and combined version-DAG cases beyond the tested producer sequence.
- [x] Default-deny permits, connection isolation, non-deterministic flags and cleanup after exceptions/cancellation errors.
- [ ] Complete adversarial current-policy/epoch, pending-work/conflict, revocation and deletion behavior across every incoming table.
- [x] Real schema-27 SQLite/backup/executable migration and already-open writer fencing.
- [ ] Explicit incoming derived search/audio/speaker/visual index and peer-versus-local extraction acceptance.
- [ ] Media-byte crash recovery and complete graph closure in addition to verified text-only process death.
- [x] Current full/sanitizer/optimized, source-scale and staged package/API/MCP/SDK/backup/erasure gates with frozen inputs.

## Full incoming library scope

| Data | Current path / remaining work |
| --- | --- |
| Sources and source-linked recaps | Typed projection and preservation described above; remaining acceptance cases stay explicit. |
| Conversations, turns and chat citations | Internal typed adapter with shared final dependency/head auditing. |
| Recap citations | Match the owner's complete wire provenance; tested delete-before-replacement retires old global lifetimes. |
| Evidence pins | Exact historical binding survives source replacement. |
| Recipes and run history | Typed incoming projection, disabled execution authority, local revision mapping and peer run attribution remain required. |
| Entities, aliases, mentions and corrections | Typed incoming projection, collisions, exact anchors and extraction provenance remain required. |
| Service and media | Safe content-addressed staging/format admission, current-policy/epoch barriers, lifecycle/backpressure, enrollment/keys, transport/providers and two-Mac acceptance remain required. |

This component does not complete cache-only erasure selection, cross-device erasure epochs, historical playback/export/save-recap, native/physical capture/power or notarized distribution. All 78 feature-status totals remain unchanged; F059 stays TODO.
