# Recoverable membership format migration — WIP

F059 remains TODO. This internal migration upgrades an already-cleared native36 format-1 preview to format 2 and rotates its native writer generation. Ordinary content remains native33 and ordinary enrollment remains native35. Public post-delivery membership controls remain disabled. This follows the separately qualified [new-handover format floor](SYNC-MEMBERSHIP-FLOOR-WIP.md).

The migration uses the original pairing and delivery accounts, protection tier, signed certificate, private material, physical binding and installation. A small pending record in the delivery envelope binds the original pairing-envelope digest, current material/head, original generation/checkpoint and one exact successor generation/checkpoint. It cannot overlap membership handover or retirement. No joining response, peer addition, secret replacement, provider connection or account creation is involved.

An explicit stopped, producer-drained owner prepares the upgrade. It requires the original active format-1 state and stopped native service command token, then rotates the generation and saves format 2 with exactly one checkpoint advance inside SQLite. The private pending envelope is saved before COMMIT. Already-admitted writers remain subject to the persistent generation guard. Supported active format-2 libraries return without another checkpoint, generation rotation or private save.

After an interrupted or ambiguous private save, a distinct existing-only restricted recovery path accepts only the exact saved original or completed native target. It verifies the original accounts, pairing bytes, material, signed head, binding, guards, roster, generation and checkpoint. It does not run ordinary migrations, invent credentials, substitute a new target or discard queues. Recovery commits the saved target if needed, then clears only that pending record by compare-and-swap. The restricted connection remains quarantined until close; normal access needs a fresh admitted store.

The async transfer API joins an uncancelled worker through completion and close. Cancellation is checked before intent. Once the private intent is saved, cancellation of the caller does not interrupt completion or abandon the worker. In the tested drained-store paths, an ambiguous failure closes the transferred store before returning and leaves the saved recovery record available. Retained media or SQL work can still prevent native close; the actual app/session integration must retain ownership, report/retry that failure and verify closure before replacing a workspace or detaching a vault.

Runtime `ae247dc` matches all **687 pinned runtime/test/dependency inputs** and passes independent outcome, identity, discovery, source-hash and frozen-engine provenance review. All six stages complete with zero failures and no sanitizer race warning:

| Selection | Passed | Gated skips | Failures |
| --- | ---: | ---: | ---: |
| full-debug | 2545 | 146 | 0 |
| affected-tsan | 715 | 46 | 0 |
| affected-optimized | 715 | 46 | 0 |
| owned-native | 163 | 2 | 0 |
| owned-membership-tsan | 56 | 2 | 0 |
| owned-membership-optimized | 56 | 2 | 0 |

All ten new ordinary migration methods pass each selection. The real owned process-death parent and actual frozen older-engine parent pass in all three owned build modes; the new child-only process worker skips outside its child invocation. All 43 focused membership/migration identities are accounted for. Six new SIGKILL boundaries pass before/after private intent, before/after native COMMIT and before/after pending clear, alongside the five preceding handover gates. Each new crash fixture preserves replay and confirms cleanup of the four original accounts. Nine altered-log controls and two stage-command/environment controls are rejected by the reviewer. [Reviewed receipt](../benchmarks/sync-membership-backfill-v1.json) · [Inputs](../benchmarks/sync-membership-backfill-inputs-v1.json) · [Raw source/logs and retained failures](../benchmarks/sync-membership-backfill-raw-v1.zip).

The frozen unmodified `d665a30` engine positively admits/writes/caches an authored already-cleared old652 format-1 preview. The migration first rejects native COMMIT after saving private intent. A current admitted writer preserves legitimate capture before the recovered fence; recovery uses the same target checkpoint, then rejects cached/ordinary older writes and fresh older admission on format 2. Current local erasure/renewal retains the floor and clears replay, current writes succeed, and old admission still refuses. All four original generated login-Keychain accounts are confirmed removed. The initial legacy snapshot is authored; this is not an actual older applying implementation, physical two-Mac or remote-provider result.

The archive exports explicit source, logs and manifests. It excludes fixture databases, generated credential backends, account inventories, keys and executables. All 679 original older-runtime inputs and its four-file frozen bundle remain unchanged. The executable remains `80a09cbd70547dc61b1834bd6ef2f20a5867852a9b73ab38030391d0ac7959de`; no older binary is rebuilt or resigned. Earlier successful reviews, publications, benchmarks and package inspections are not rerun.

The retained development record includes one direct synchronous cancellation/close failure and two native fixture failures. The async transfer API now joins an uncancelled worker, checking cancellation before intent and preserving saved forward recovery after ambiguous failure. The fixture now recovers/fences before releasing/joining the old child and closing its stores, respecting the child's retained media lease. No frozen worker or engine was changed to make the controls pass.

This qualifies the internal migration. Actual app/CLI session/producer integration, durable reviewed joining response/completed receipt, removal/rotation, remote capability negotiation, large/offline/provider-retention and production/device/power/distribution acceptance remain open. **F059 and all 83 feature statuses remain unchanged.**

Remaining work:

- Integrate migration and membership operations into the actual async app/CLI session and producer-drain lifecycle, including quiet recovery, saved pause, reconnect opt-in and close-failure retry before workspace/vault replacement.
- Persist/retrieve the exact reviewed joining response for initial pairing and later additions, with a completed-operation receipt across interruption/final clear, before enabling public owner additions.
- Finish removal/epoch rotation, remote client capability negotiation and the remaining offline/queue/media/provider-retention work.
- Qualify production data-protection Keychain, signed interactive GUI, physical two-Mac/provider, sustained energy and notarized distribution. These checks do not establish full parity or whole-product ranking.
