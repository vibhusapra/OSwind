# Recover the initial joining response

Closing setup after approving a Mac previously discarded the encrypted joining response from the interface. Initial approval now saves one exact response in the local encrypted inbox and commits its bounded pointer together with membership in the original private account. Reopening setup offers **Recover last joining response**, with the original request expiry and an explicit copy action. Recovery does not regenerate a response or extend its deadline.

Source `1ce80bc` binds 698 committed runtime, test and dependency inputs. A root-signed plan binds the exact reviewed request, newly added member, predecessor and successor certificates, ciphertext, group, epoch, original account, publication lifetime and approval time. The public approval API uses the live clock inside ownership and checks expiry again immediately before the private write. Deterministic clocks are internal test interfaces. Missing or corrupt saved plans refuse recovery rather than approving another device.

Only the latest response pointer is retained. Another deliberately reviewed approval may replace it. A legacy device already admitted without a saved response has a separate reviewed reissue path while its original request remains valid; this does not add a member. Expired requests still need explicit device recovery. Initial receipt metadata survives delivery reservation and an internal native membership handover, but a new publication lifetime clears it. Normal status never returns the response text.

## Qualification

| Stage | Passed | Conditional skips | Failures |
| --- | ---: | ---: | ---: |
| Full Debug | 2,572 | 159 | 0 |
| Affected Thread Sanitizer | 751 | 55 | 0 |
| Owned native response Thread Sanitizer | 21 | 1 | 0 |
| Affected optimized | 751 | 55 | 0 |
| Expanded owned native optimized | 88 | 5 | 0 |

All 25 new identities are accounted for: 22 ordinary methods, the explicit native process-death parent, its child-only worker, and an opt-in layout method. The native parent passes at final source under sanitizer and optimization. Before-save SIGKILL preserves old private state; after-save and after-return SIGKILL recover the exact committed ciphertext digest and length. The joining fixture accepts that saved response. The two original login-Keychain accounts are independently verified removed afterward. No new account is allocated for response storage. These are authored fixtures on one Mac, not physical two-Mac or production Data Protection Keychain acceptance.

Tests cover failed and ambiguous private saves, failed encrypted writes, corruption and missing plans, request expiry during preparation, stale owner review, explicit legacy reissue, provider unavailability, original-key preservation through native handover and actual app departure joining a blocked credential read despite cancellation. A full-membership fixture's plan is 73,142 bytes against the 327,680-byte bound; that is one fixture, not a worst-case performance measurement. Five altered-log controls reject invalid evidence.

A fresh production app passes strict ad-hoc signature verification. Every bundled resource and the bundle information match the preceding qualified package. All 688 unchanged preceding inputs and 475 earlier benchmark, feature and landscape publications remain unchanged.

- [Reviewed receipt](../benchmarks/sync-owner-response-v1.json)
- [Committed input hashes](../benchmarks/sync-owner-response-inputs-v1.json)
- [Raw source, logs, receipts and generated layouts](../benchmarks/sync-owner-response-raw-v1.zip)

Earlier development also passed four offscreen light/dark layouts and native crash checks. Two layouts were manually inspected. Those observations predate the final verifier and clock refinements; they are separate from the final native protocol qualification and do not establish foreground input, keyboard or VoiceOver acceptance. The original private-type test compilation failure and incorrect busy/credential-lease assertion remain retained. An earlier full-debug run was stopped unfinished for the verifier/time review; its partial output is not a full-suite pass.

## Remaining work

First-time private inbox creation still uses the existing final-directory-before-marker helper. Early interruption can leave an incomplete final directory; atomic staging and publication are the next hardening slice. Current crash controls cover later approval save boundaries and do not prove this earlier case.

Public post-delivery owner addition remains disabled. Its completed delivery receipt, actual producer/session handover, close-failure retry, quiet reconnect restoration and remote software capability negotiation remain necessary. Removal and epoch rotation, older-device recovery, provider retention and queue pressure, physical two-Mac operation, energy and signed/notarized distribution also remain open. The interface still describes a two-Mac preview; a 64-member bounded protocol fixture does not qualify a 64-device product.

Parent PR151's hosted benchmark job passed, but its native encrypted-APFS selection failed during disk-image creation before the held-reader assertions. The current helper omitted that creation result from its observer, leaving its underlying native exit/stderr and cause unknown. The failure is retained and safe creation diagnostics are a separate follow-up; later passing runs cannot explain it retroactively.

F059 remains TODO. All 83 feature statuses are unchanged. This component does not qualify complete sync, v0 completion or a product ranking.
