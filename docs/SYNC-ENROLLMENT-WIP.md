# Personal sync enrollment — credential foundation WIP

The core can now save and reload its private device/owner/group key material through a dedicated Keychain backend and validate a saved native-library binding. The [native pairing preview](SYNC-PAIRING-PREVIEW.md) now supplies a public core owner and resumable create/join/review/acceptance UI over a dedicated Keychain envelope. Delivery session activation remains unfinished; F059 remains TODO. This document retains the earlier credential-foundation evidence below.

Private key types remain non-Codable and redact descriptions and Mirror. Only an explicit bounded private-material encoder produces Keychain bytes. Reload checks the certificate, device keys and optional owner authority. An owned native test saves a generated 64-member group's material, reloads the original signing and agreement keys, verifies a packet and opens the original encrypted space, then confirms removal of its disposable credential.

The Keychain namespace is separate from model providers, MCP and vault passphrases. Login and data-protection storage are explicit modes. Missing items are not silently recreated; duplicate creation and stale expected bytes refuse replacement/deletion. The mutation API still requires the enrollment owner's cross-process lease; this is not a Security.framework/SQLite atomic transaction.

Data-protection storage returned `-34018` in the XCTest host and did not fall back to login storage. That is a capability observation, not production OSwind app entitlement acceptance. Login-Keychain storage and software admission do not establish Secure Enclave or hardware device-only binding. [Apple's implementation guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) and [accessibility requirements](https://developer.apple.com/documentation/security/ksecattraccessible) explain why the implementations must be distinguished. All probes used fresh owned accounts and generated material; existing credentials were not enumerated or read, and the generated entries were confirmed removed.

## Native binding and lifecycle boundaries

The binding includes this installation's atomically published identity, a locally hashed Mac identifier, capture origin/generation, native publication lifetime, filesystem volume and directory inode, group/epoch/replica/root fingerprint and selected protection mode. The raw hardware identifier is never logged or saved. A held per-credential file lease excludes another actual process; closed or replaced lock identities refuse use. Existing missing installation identities require recovery. Concurrent first enrollment uses atomic `mkdir(..., 0700)`, avoiding Foundation's transient broader directory mode.

Capture generation does not rotate on whole-library wipe. The actual `sync-publication-library-lifetime-v1` marker is the relevant retirement boundary. Binding to the generic `store_metadata.identity` would be incorrect because individual source erasure also changes it. Tests verify that enrolled whole wipe invalidates the binding while individual source erasure preserves it. Ordinary library copies are refused; a same-volume rename remains valid.

An encrypted APFS image copy preserves its inner volume UUID and inode. A retained native regression fixture reproduced acceptance before the fix. Binding now also pins the outer host volume and package/sparsebundle inodes. The positive fixture unlocks the original again, proves the copied inner IDs/origin/publication lifetime match, refuses the copied package, preserves its source, closes both stores and detaches both images. An independent post-test attachment observation finds no owned images left attached. This is not a general whole-machine rollback guarantee.

## Focused checks

Source `e6ed33e` and the [development receipt](../benchmarks/sync-enrollment-development-v1.json) record **17 new regular methods** passing debug, Thread Sanitizer and optimized checks. The selected sanitizer and optimized sets each pass **39 methods / 5 native skips**, including the earlier pairing/signed-transport controls. The explicit owned native run passes **22 methods without skips**, including **5 native probes**. No race warning appears. Earlier native binding assumptions, concurrent-directory failures and the encrypted-vault-copy counterexample remain retained with their corrections.

These are focused development checks. They are separate from the [published signed-transport qualification](SYNC-SIGNED-PAIRING.md), and establish no public setup, full source/package qualification, real two-Mac/provider acceptance, power budget, notarized distribution or whole-product ranking.

## Next delivery work

- Extend the implemented pending/joined/owner/retired pairing envelope into a verified active-delivery credential lifecycle; keep every private key out of SQLite, settings, argv, environment and provider objects.
- Advance an external writer sequence/digest ceiling before provider publication, and preserve received head/erase/receipt checkpoints. Refuse restored or cloned stale writer state; do not claim global freshness from a withholding provider.
- Enforce enrolled native writer capability admission, including already-running old clients. Ordinary unenrolled native33 and frozen compatibility evidence must remain meaningful.
- Connect the implemented native create/join/fingerprint preview to verified session/folder activation through the owned setup boundary, with actual status, cancellation and partial-install cleanup. A paired identity is not an active delivery session.
- Integrate native local/received erase drain, physical cleanup and exact completion into credential binding renewal; never reset causal/deletion history to reconnect.
- Finish membership refresh, recovery/revocation/rotation, cold offline and raw-queue pressure, large resumable graphs and selective spool/backup semantics. Revisit the full 83-feature matrix, local GPU/BYOK/design, sustained power and distribution gates.
