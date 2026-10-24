# Verifying encrypted-image detach

A successful `hdiutil detach` is followed by OS inventory verification before OSwind reports a vault locked. The retained audio-ingress qualification encountered an unidentifiable unmounted APFS attachment after a lock attempt; later independent inventory found no owned image and a normal retry confirmed detached. Its exact failing inventory was not captured, so its root cause remains unproven.

The new verifier handles a specific conservative case: after a successful normal detach, `hdiutil info` can still list the known image while its APFS volume entity is absent. This is treated as an incomplete observation, not proof of detach. Multiple candidate volumes and other ambiguity remain errors.

## Confirmation contract

The normal detach path keeps the existing image, device, volume UUID, mount and root identity checks. The moved-image fallback still uses only a verified normal kernel unmount and normal detach; busy readers are not overridden. No force flag or additional detach attempt is introduced by verification.

Before the detach command, the verifier captures package/manifest/image identity, including an explicit current package stamp even if the vault object was constructed before the package existed. After successful detach it performs up to eight observations, with 50 ms asynchronous pauses between them. Every observation validates the original package, manifest vault/volume/setup identity and image device/inode before native inspection and again after a usable reply. The image's mutable directory size/timestamps are not treated as identity.

Two consecutive fresh absent observations are required. A still-attached observation or the typed missing-volume observation resets that count. A changed attachment, package, image or manifest; an unknown inspection failure; or cancellation prevents successful confirmation. Exhaustion preserves the pending/error state and tells the user to retry locking. Native helper calls retain their own timeouts, so eight attempts and 350 ms of pauses are not a hard wall-clock deadline.

Only the specific missing unmounted-volume entity is retried after successful detach. Initial inspection failures, multiple unmounted volumes, invalid device/layout/UUID metadata and failures between the moved-image kernel-unmount and final-detach stages retain their existing refusal behavior. This is not a general retry around every native error and does not prove the original retained failure had this exact cause.

## Evidence

Deterministic cases cover incomplete/attached/absent sequences, reappearing attachments, budget exhaustion, immediate propagation of unknown/changed identity, cancellation before/during/after native replies, and actual image/package/manifest replacement with preserved original/replacement bytes. An opt-in native fixture rapidly unlocks, writes and locks an owned encrypted image, independently checks `hdiutil info` after every close and reopens all six original sources. It uses a random test passphrase through stdin, no Keychain, no user library and no forced detach.

```bash
swift test --filter VaultDetachSettlementTests
OSWIND_TEST_NATIVE_VAULT=1 swift test \
  --filter 'VaultDetachSettlementTests|NativeVaultTests|VaultSessionTests'
```

Controlled sequence fixtures prove the verifier's decisions; they are not direct recordings of every possible APFS/Disk Arbitration transition. Native repetition verifies the ordinary owned-image lifecycle and history preservation. Broader OS/hardware, authentication, failed-device and timing behavior still need independent acceptance.
