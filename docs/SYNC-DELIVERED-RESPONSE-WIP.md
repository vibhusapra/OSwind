# Durable response for an enrolled owner's membership change

Core source `9f47c460af56436c3f201d2a60495c94bf52cca6` saves an exact encrypted joining response alongside an internal post-delivery membership operation. The final existing private-account compare-and-swap both clears the operation and promotes its response reference. A crash after that save does not lose the response or require generating another admission.

**Public post-delivery owner approval remains disabled.** This foundation does not yet provide the full app session, producer drain, failed-close retry or fresh-workspace flow. F059 remains TODO and all 83 feature statuses remain unchanged.

## Behavior and boundaries

The pure signed membership proof keeps its existing address, format and size bound. An optional reference points to a separately addressed encrypted approval plan in the original private inbox. The reference binds the plan's original pairing account and pairing lifetime, exact signed target membership, and a separate delivery publication lifetime. Pairing and publication lifetimes are distinct authorities; legacy publication identifiers remain accepted under their existing format.

Preparation retains the prior completed receipt. Applying a pure signed membership update and upgrading an older membership floor also preserve it. Cancelling a later approval preserves the previous completed response. Whole-library retirement clears the completed reference before the publication lifetime disappears. Optional absent fields preserve legacy canonical encoding.

Review and preparation are internal. They require the exact original owner state and a new request, reject already-admitted/stale reviews, check a live clock during preparation and again at the actual initial private-save boundary, and refuse while the original live session owns its delivery lease. There is no new credential account or provider-folder dependency for response storage/recovery.

Explicit recovery reads the latest completed response through the original private authority and validates its encrypted content reference, original account/lifetime, signed binding and historical path to the current head. A pending operation, missing or corrupt latest plan refuses; it cannot silently become an older initial response. Expired ciphertext can be recovered byte-for-byte but cannot extend joiner acceptance. Status reports availability without returning response ciphertext.

This builds on [native membership handover](SYNC-MEMBERSHIP-HANDOVER-WIP.md), [older-client backfill fencing](SYNC-MEMBERSHIP-BACKFILL-WIP.md), [initial pre-delivery response recovery](SYNC-OWNER-RESPONSE-WIP.md) and [atomic private-inbox publication](STORAGE-SETUP-RECOVERY.md). Existing private-Keychain authority assumptions still apply: selective malicious rollback of a private envelope is not separately prevented by this receipt.

## Source-bound qualification

- **715 committed inputs**, seven changed source/test files, 708 unchanged base inputs. Fourteen new ordinary methods and two gated process methods.
- Full Debug: **2,633 passed, 166 conditional skips**. Broad sync/library-opening sanitizer and optimized selections: **772 passed, 58 skips each**. Zero failures/race diagnostics.
- Explicit native selections: **78 passed, three child-only skips each** under sanitizer and optimization. They include original login-Keychain approval/membership/recovery, earlier response/backfill death gates, and actual frozen native35/36 client refusal checks.
- The new delivered-response parent performs real SIGKILL at **intent, decision, pairing, delivery, commit, clear and after-response**. Each phase recovers exact ciphertext, preserves original private keys and the canary, allows the intended recipient to accept, and removes its three generated original Keychain accounts. The Core after-response boundary is not app UI return acceptance.
- The reviewer checks exact method identities/states and independent aggregate summaries, source/log hashes, every required seven-phase marker and original fixture hashes. Five altered XCTest logs and three altered death records reject.
- Normal production build and a fresh strict ad-hoc app package pass. All 34 package files are recorded; prior bundled resources/Info remain unchanged and executable modes are 0755. This is not Developer ID signing or notarization.

A single host observation during optimized functional qualification reported roughly 60 GB of swap in use and low free storage. Only inactive generated compiler module caches and a debug index were reclaimed; pinned source and frozen fixtures remained unchanged. These correctness runs do not establish controlled performance or energy, and this observation does not identify the cause of storage pressure.

Development failures remain retained. The first scope check incorrectly used the restricted database reader for an ordinary library; correcting that scope restored existing initial-response cases. A test initially accessed fileprivate review bytes and was corrected to retain its input request. A later lifecycle fixture lacked a saved bookmark: its live-session check failed, and its provider-absence assertion was insufficient. Both final checks now create a real public session/bookmark first and pass. No production visibility or guard was weakened for tests.

An earlier successful seven-phase Debug-native run remains frozen. Its later source-hash record matches the final five Core files and crash file, while the ordinary test file subsequently gained two cases; it is not a predeclared final-binary receipt. Final pinned sanitizer and optimized runs qualify the complete committed source independently.

[Reviewed receipt](../benchmarks/sync-delivered-response-v1.json) · [Committed inputs](../benchmarks/sync-delivered-response-inputs-v1.json) · [Raw source and logs](../benchmarks/sync-delivered-response-raw-v1.zip). All **502 preceding benchmark publications** remain byte-identical. Raw evidence excludes databases, executable binaries, model weights, account inventories, credentials and user history.

## Next acceptance work

The app must bind reviews to the exact live session/library/root/head, retire and drain actual producers, stop/join the exact session, reacquire original accounts and revalidate after that gap. Membership-owner close must retain both original credential leases until SQLite/media close actually succeeds; this foundation still releases them first, so that failed-close behavior remains an explicit prerequisite for a public operation. The app must retain the owner/store through close failures and retry cleanup before any fresh routine store or vault detach. A fresh quiet AppModel must replace the retired model only after actual close; saved manual reconnect/network pause and paused recording must survive. Lock, termination, move, cancellation and recovery must join the same operation.

The existing frozen native35/36 fixtures exercise pure-proof handover/backfill. Before app enablement, the immediately preceding format2 package also needs a fresh/cached writer check against a library containing the new completed-response field; that specific compatibility is not inferred from these older fences.

Removal, epoch rotation, remote software capability handling, provider retention and queue pressure remain additional sync work. Physical two-Mac operation, uninterrupted 24-hour capture, power measurements, production credential/signing/notarization and broad GUI/input acceptance are still open. This component establishes neither whole-product feature parity, complete v0 nor a top-three ranking.
