# Complete answer publication

An answer can arrive before the citation that reveals erased evidence. Deleting the answer when that citation finally arrives leaves an earlier disclosure window. The internal sync publication path now requires an authenticated declaration of the complete citation set before exposing an answer in native history.

**Component qualified at `6b068ed`; F059 remains TODO.** This is a protocol and native admission prerequisite. It enables no sync service, enrollment, watcher, account or network listener. The existing lower-level record adapters remain internal components; they do not themselves establish complete publication.

## Publication contract

| Input or event | Result |
| --- | --- |
| Outgoing answer snapshot | Prepare its exact immutable body and every native citation from one SQLite writer transaction. Require contiguous ordinals, unique identities, at most 60 citations and a declaration no larger than 1 MiB. |
| Declaration retention | Durably retain immutable, content-addressed declaration bytes before publishing their hash on the answer's journal revision. The encrypted object-folder transport refuses a revision whose declaration is absent. |
| Authentic empty declaration | A source-free answer can become readable immediately. An absent declaration never means an empty citation set. |
| Missing declaration or child journal head | Return an explicit withheld outcome. Journal receipt/cursor progress is distinct from readable native projection. Later independent records can progress. |
| Complete, admitted publication | Project the answer, historical originals and every declared citation in one transaction. Recheck the exact graph before committing. |
| Genuine erasure of declared evidence | Retire the answer under the authentic evidence barrier before body/media admission or erased-source fetch. The declaration must belong to the admitted owner version and trusted group/epoch. |
| Unlisted or changed citation | Withhold it. An unrelated citation cannot authorize deleting an independently valid answer. Exact canonical content references distinguish byte changes, including Unicode representation. |
| Citation conflict | Withhold for review. This component does not choose a user resolution. |
| Replacement would leave excluded native citations | Withhold with `replacementRequiresReview`. Projection detachment/replacement lifetimes remain open. Existing complete native history is not relabeled as the new body. |
| Cancellation, policy failure or reentrant mutation | Roll back the publication group and its receipt. An immutable encrypted declaration blob may remain as an unreferenced orphan after outgoing rollback. |

The declaration binds group, epoch, exact owning version and ordered complete citation records. The answer revision authenticates its declaration content reference. Citation head authority still comes from the journal; arbitrary fetched packets do not count as received child revisions. Original source versions and media retain the existing typed admission and historical-evidence checks.

The raw answer record's content hash stays unchanged. Legacy revisions without a declaration retain their encoded shape. An actual previous protocol decoder must refuse revisions carrying the new field through its canonical-byte check; successful decoding that silently drops the field is insufficient.

## Tests and qualification

Source: `6b068ed0f0e469c8bdf5a48b93c2db37e880aece`. [Qualification receipt](../benchmarks/sync-answer-publication-v1.json) · [824 input hashes](../benchmarks/sync-answer-publication-inputs-v1.json).

- The original owned three-replica test failed with two assertions: one readable turn and its canary text appeared before the withheld citation. The corrected publication path passes that intermediate check.
- The focused selection currently defines 21 cases: 20 required passes and one crash-worker-only skip. It covers complete and empty declarations, exact child versions, missing/legacy declarations, independent sender progress and explicit retry, wrong epochs, tampering, unlisted erased citations, replacement refusal, outgoing durable-sink failure and reentrant mutations.
- A policy callback fails after the first native citation is written; the whole answer, citations, new original admissions and last receipt roll back.
- Actual SIGKILL occurs during the second citation and after commit. An independent read-only SQLite connection observes zero partial answer/citation rows before commit and the whole answer afterwards. Reopen and idempotent retry verify original text, cached bindings, receipts, cursor, accounting and no echo.
- Full debug passes **1,953 cases / 96 explicit skips**. Thread Sanitizer and optimized selections each pass **543 cases / 36 skips**, with no race warnings. All **57 mandatory controls** (the 20 new publication cases and 37 prior unavailable-scope controls) execute in all three builds. All **39 owned native vault cases pass without skips**. Full/native selections cover **1,990 distinct passed methods**. All **31 qualification stages** pass, including staged CLI/HTTP/MCP/SDK, backup/retention/APFS interruptions, eight schema32 process groups, actual older-client refusal and strict **34-file app/archive equality**. All **36 prior app trees remain unchanged**.

Independent read-only review checks all six recovered closed databases across debug, sanitizer and optimized builds: exact native frames, canonical source and historical bodies/fingerprints, cached projection bindings, current owner declaration, receipt/cursor, accounting and no echo. Isolated probes compiled from the unmodified previous/current protocol files accept the legacy positive control; the previous source refuses the actual recovered declaration-bearing revision while the current source accepts it. These are codec probes with minimal linking stubs, not a full old-app/provider acceptance claim.

Earlier logs remain retained. In addition to the genuine initial visibility failure, development corrected a pre-projection cache lookup and test oracles for trailing pin packets and an already-admitted pin's historical original. The latter are not additional product regressions.

To exercise the focused owned fixtures from the repository root:

```sh
swift test --filter 'SyncIncomingSourceTests.test(Publication|IncompleteCitedTurn)|SyncTurnPublicationProtocolTests'
```

To retain the two recovered crash fixtures, choose a fresh output path whose parent exists:

```sh
mkdir -p .artifacts
OSWIND_TEST_INCOMING_SOURCE_ROOT="$PWD/.artifacts/publication-recovery" \
  swift test --filter 'SyncIncomingSourceTests.testPublicationDeath'
```

The tests refuse an existing case output instead of mixing two attempts. The retained state contains authored text and owned SQLite libraries. Source-free/complete positive controls and the privacy failures use real native creation, outgoing packets, journal receipts and typed incoming writers.

## Remaining delivery work

The future service needs a durable, bounded queue and lifecycle for withheld publications, recovery/retry/status, cancellation and current-policy denial. A receipt alone must never be displayed as successful native projection. This component exposes explicit outcomes; it does not implement that scheduler.

Also open: reviewed citation replacement/detachment, source/media transport and current policy, unknown-offline-object collection erasure, trusted epoch transitions and backup rollback/recovery, revocation, acknowledged compaction, enrollment/key recovery/conflict UI, provider acceptance and two actual Macs. F013 sustained capture/power and F067 notarized distribution remain open. There is no new competitor ranking, energy result or whole-product parity claim.

The [83-requirement ledger](features.json), [20-offering research](landscape.html), [unavailable scope qualification](SYNC-UNAVAILABLE-SCOPES.md) and earlier source-bound component receipts retain their separate completion boundaries.
