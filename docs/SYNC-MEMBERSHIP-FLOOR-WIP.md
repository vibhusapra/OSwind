# Membership state format floor — WIP

The separately qualified [recoverable preview migration](SYNC-MEMBERSHIP-BACKFILL-WIP.md) at `ae247dc` implements the already-cleared format-1 backfill that remained open at this earlier checkpoint. This file records the preceding runtime; actual public session/owner-add integration and full F059 acceptance remain unfinished.

F059 remains TODO. New internal handovers now write membership state format 2, while the SQLite library remains native36. Ordinary content remains native33 and ordinary enrollment remains native35. Public post-delivery membership editing stays disabled. This is a local library compatibility boundary; remote software capability negotiation remains separate work.

The original compatibility concern is now reproduced with an actual earlier engine. An owned XCTest bundle links unmodified `d665a30` product/runtime/dependency sources: all 679 original inputs match the committed preparation receipt, with one separately hashed test-only worker entry point. The worker can read only the parent's four explicitly listed login-Keychain accounts and refuses account creation, replacement and deletion. It uses the real Mac fingerprint and owned installation/library paths. Its executable is frozen at SHA-256 `80a09cbd70547dc61b1834bd6ef2f20a5867852a9b73ab38030391d0ac7959de`.

Before the fix, that engine positively opens/adopts native36 format 1, writes a legitimate raw canary and prepares another SQL write. The committed preparation fences its cached SQL and ordinary writer during handover. However, a fresh old-engine process subsequently opens completed format 1 even while the new runtime's replay cursor remains pending. The baseline confirms admission of an older runtime that does not implement replay. It does not reproduce an old-engine erasure failure or claim a physical-device result.

New handovers commit active format 2 before clearing their private pending record. The old engine requires format 1 and now refuses normal admission specifically on the unsupported state format. Current software reads supported formats 1 and 2. A preparation record optionally saves the original native36 state version; absence retains the legacy format-1 interpretation. A later preparation/cancellation after a format-2 handover preserves format 2, and the supported state writer refuses a downgrade. Existing generation rotation fences already-admitted older writers. The phase/state metadata remains protected by the existing private membership capability.

The actual old-engine test now checks positive legacy admission and SQL mutation, cached/ordinary write refusal across handover, fresh format-2 refusal, preservation of local capture, and fresh current admission. It also completes local erasure/cleanup/renewal: replay intent is cleared, format 2 remains, a new current writer works and another old-engine process still refuses. Those same four original login-Keychain accounts are retained through the operation and confirmed removed at the end. The frozen executable is never rebuilt or resigned after use.

Legacy pending preparation/cancellation records omit the new optional field and retain their canonical recovery behavior. An already-committed but still-pending older applying record can contain active format 1 at its exact saved final token. Recovery verifies the exact signed head, original private hashes/accounts, updated roster, token and writer generation, then upgrades only the native format before clearing the pending record. It does not repeat peer additions, change keys or consume another token. A rejected upgrade COMMIT is tested and resumes the same final target; only the final private pending clear saves externally. The original preparation already rotated the writer generation, and its still-pending private record blocks fresh ordinary admission during this narrow recovery.

Already-cleared format-1 previews are different: an old client could have been admitted after their earlier handover. Current code can finish their existing replay without discarding it, but simply rewriting their format would not fence such a cached writer. A separate owned backfill operation must durably save intent, rotate that library's writer generation, preserve legitimate pre-fence raw capture and recover an exact external/native checkpoint before claiming retroactive protection. That migration is **not implemented** here and remains required before complete public integration. New replay seeds require format 2; reading a legacy cursor does not claim that its older library has been backfilled.

Runtime `802d0e3` matches all **682 pinned runtime/test/dependency inputs** and passes independent outcome, identity, discovery, source-hash and frozen-engine provenance review. All six stages complete with zero failures and no sanitizer race warning:

| Selection | Passed | Gated skips | Failures |
| --- | ---: | ---: | ---: |
| full-debug | 2534 | 144 | 0 |
| affected-tsan | 705 | 43 | 0 |
| affected-optimized | 705 | 43 | 0 |
| owned-native | 151 | 1 | 0 |
| owned-membership-tsan | 44 | 1 | 0 |
| owned-membership-optimized | 44 | 1 | 0 |

All four new ordinary regression methods pass each build selection. The fifth new method uses the actual frozen older engine and real owned login-Keychain accounts; it passes in the three owned selections and skips only when those native inputs are not enabled. That test positively admits/writes legacy native36, fences cached SQL and normal writes, refuses fresh older admission specifically on format2, then erases/renews through the current runtime and verifies the floor/replay cleanup/current write/old refusal again. Original four-account cleanup is asserted. All 30 focused membership identities are accounted for, including the child-only process worker skip; all five existing SIGKILL boundaries continue to pass in the three owned modes. Seven altered-log controls are rejected by the reviewer. [Reviewed receipt](../benchmarks/sync-membership-floor-v1.json) · [Inputs](../benchmarks/sync-membership-floor-inputs-v1.json) · [Raw source/logs/baseline/retained failures](../benchmarks/sync-membership-floor-raw-v1.zip).

The archive contains explicit source, logs and manifests, including the original old-engine baseline and its child logs. It contains no generated fixture database, private credential backend, private key or executable. The initial bad XCTest wrapper and corrected same-byte wrapper are retained. All 679 original older-runtime inputs remain unchanged; only the separately hashed worker is added. Old executable/library hashes are checked before and after every stage; linkage inspection finds only platform/toolchain/test support libraries. Earlier successful reviewers, publishers, benchmarks and package inspections are not rerun.

These results qualify new handovers and still-pending legacy recovery as described above. They do not implement the separate backfill fence for already-cleared format1 previews, public membership controls, remote client-build negotiation, production DP-Keychain, signed interactive GUI, physical two-Mac/provider, sustained energy or notarized distribution. **F059 and all 83 feature statuses remain unchanged.**

Remaining work:

- Implement the durable owned backfill for already-cleared format-1 previews, including cached old writers, ambiguous private saves, rejected native commits, cancellation and actual process death.
- Finish the durable exact reviewed joining response, actual app/CLI session/producer ownership and recovery controls.
- Implement reviewed removal/epoch rotation, remote client capability negotiation and the remaining offline/queue/media/provider-retention checks.
- Complete production data-protection Keychain, signed interactive GUI, physical two-Mac/provider, sustained energy and notarized distribution acceptance. This component does not establish whole-product parity or ranking.
