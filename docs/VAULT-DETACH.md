# Verifying encrypted-image detach

A successful `hdiutil detach` is followed by OS inventory verification before OSwind reports a vault locked. The retained audio-ingress qualification encountered an unidentifiable unmounted APFS attachment after a lock attempt; later independent inventory found no owned image and a normal retry confirmed detached. Its exact failing inventory was not captured, so its root cause remains unproven.

The new verifier handles a specific conservative case: after a successful normal detach, `hdiutil info` can still list the known image while its APFS volume entity is absent. This is treated as an incomplete observation, not proof of detach. Multiple candidate volumes and other ambiguity remain errors.

During schema-21 entity qualification, the earlier eight-observation/350 ms pause budget failed three native cases and three isolated diagnostic runs. An independent probe observed the known image without its APFS volume for approximately ten seconds before repeated inventory replies omitted it. Additional diagnostic IPC can affect timing; it did not capture the verifier’s callbacks or establish the OS cause. The adaptive window below preserves the first fast confirmation and all identity/error checks while allowing this longer settling state. All 24 focused deterministic/native detach, migration and credential-fixture cases pass with that candidate. Full package requalification is recorded in the progress ledger; earlier failures remain retained.

## Confirmation contract

The normal detach path keeps the existing image, device, volume UUID, mount and root identity checks. The moved-image fallback still uses only a verified normal kernel unmount and normal detach; busy readers are not overridden. No force flag or additional detach attempt is introduced by verification.

Before the detach command, the verifier captures package/manifest/image identity, including an explicit current package stamp even if the vault object was constructed before the package existed. After successful detach it performs up to sixteen observations. The first asynchronous pause is 50 ms, followed by 100, 200, 400 and 800 ms, then pauses capped at one second. Across fifteen pauses the configured maximum is 11.55 seconds. Every observation validates the original package, manifest vault/volume/setup identity and image device/inode before native inspection and again after a usable reply. The image's mutable directory size/timestamps are not treated as identity.

Two consecutive fresh absent observations are required. A still-attached observation or the typed missing-volume observation resets that count. A changed attachment, package, image or manifest; an unknown inspection failure; or cancellation prevents successful confirmation. Exhaustion preserves the pending/error state and tells the user to retry locking. Native helper calls retain their own timeouts, so sixteen attempts and 11.55 seconds of pauses are not a hard wall-clock deadline.

Only the specific missing unmounted-volume entity is retried after successful detach. Initial inspection failures, multiple unmounted volumes, invalid device/layout/UUID metadata and failures between the moved-image kernel-unmount and final-detach stages retain their existing refusal behavior. This is not a general retry around every native error and does not prove the original retained failure had this exact cause.

## Evidence

Deterministic cases cover incomplete/attached/absent sequences, reappearing attachments, budget exhaustion, immediate propagation of unknown/changed identity, cancellation before/during/after native replies, and actual image/package/manifest replacement with preserved original/replacement bytes. An opt-in native fixture rapidly unlocks, writes and locks an owned encrypted image, independently checks `hdiutil info` after every close and reopens all six original sources. It uses a random test passphrase through stdin, no Keychain, no user library and no forced detach.

```bash
swift test --filter VaultDetachSettlementTests
OSWIND_TEST_NATIVE_VAULT=1 swift test \
  --filter 'VaultDetachSettlementTests|NativeVaultTests|VaultSessionTests'
```

Controlled sequence fixtures prove the verifier's decisions; they are not direct recordings of every possible APFS/Disk Arbitration transition. Native repetition verifies the ordinary owned-image lifecycle and history preservation. Broader OS/hardware, authentication, failed-device and timing behavior still need independent acceptance.

## Qualified runtime

[Runtime d224bff](../benchmarks/vault-detach-settling-v1.json) passes 745 normal cases (714 pass/31 opt-in skips), 247 native/model cases and one distinct physical audio case: 739 distinct passes/six remaining opt-in cases. All 283 focused race cases plus physical audio pass. The staged signed package and twelve process groups qualify, with three independent complete vault processes. The exact signed CLI also passes real targeted synthetic OCR/privacy/deletion.

An intermediate full run failed a synthetic snapshot callback assertion while real host sleep invalidated capture work; OS power timestamps and the failed run are retained. Custom snapshot environments now receive a private lifecycle center; production explicitly uses NSWorkspace. A new injected-sleep case confirms pending synthetic capture is still cancelled before admission. This prevents real host events from redefining a fake world and keeps the live privacy behavior.
