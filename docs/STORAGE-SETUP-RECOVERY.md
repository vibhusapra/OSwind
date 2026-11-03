# Interrupted private setup and native storage diagnostics

An interruption during the first local sync-inbox creation could leave the final directory without its authenticated marker. Source `49f259d` prepares and verifies the complete marker in an owned workspace, closes the staged reader, and publishes with the existing physical-parent/inode checks, nonreplacing rename and directory flush. Cancellation or failure cleans only that workspace. A later attempt can clean a recognized abandoned workspace after process death and retry the original namespace. Existing files, folders and symlinks are preserved and refused. An invalid final directory left by an older version is not silently deleted.

The change applies to the private local inbox. User-selected shared transport creation keeps its existing workflow. It complements [exact initial response recovery](SYNC-OWNER-RESPONSE-WIP.md); it does not enable post-delivery member addition or complete device sync.

Native image create/attach now use the existing internal result observer. Diagnostics retain exit/signal, elapsed duration, byte counts, hashes and bounded stderr. Credential input, arguments and create/attach stdout are excluded. The actual fixed `hdiutil` commands, stdin-only credential, finish-on-cancellation ownership, helper callback and original public error messages are preserved. Mutations are not retried. Ordinary product drivers have no diagnostic observer installed.

## Qualification

[Reviewed receipt](../benchmarks/storage-setup-recovery-v1.json) · [700 committed inputs](../benchmarks/storage-setup-recovery-inputs-v1.json) · [Raw evidence](../benchmarks/storage-setup-recovery-raw-v1.zip).

| Selection | Passed | Conditional skips | Failures |
|---|---:|---:|---:|
| Full Debug | 2,581 | 162 | 0 |
| Affected ThreadSanitizer | 281 | 70 | 0 |
| Owned native ThreadSanitizer | 74 | 1 | 0 |
| Affected optimized | 281 | 70 | 0 |
| Owned native optimized | 74 | 1 | 0 |

All 12 new method identities are accounted for. Nine ordinary methods pass in Debug, sanitizer and optimized builds. The opt-in parent performs a real SIGKILL before publication, checks absent final state, cleans abandoned staging and retries the original namespace; it creates no credential accounts. Its child-only method remains a deliberate skip when not directly invoked. The third gated method invokes the real native create helper against an owned invalid parent and records status 1 / `Not a directory`, with the canary intact and no image created. That controlled error does **not** establish the cause of PR151's earlier hosted image-creation failure.

Both owned modes also pass all seven existing native cancellation/held-reader methods, original login-Keychain pairing and app vault-session checks. Five altered-log controls reject missing, duplicate, wrong-identity, failed and race-contaminated evidence. The fresh production app passes strict ad-hoc verification; its resources and bundle information match the preceding package. All 692 preceding unchanged inputs and 478 preceding publications are verified. Successful historical runs and the ongoing capture workers remain untouched.

CI now explicitly selects the owned inbox process-death parent and retains the controlled create diagnostic alongside existing native traces. Hosted validation of that workflow is a later observation. Parent PR152 separately completed its [hosted workflow](https://github.com/vibhusapra/OSwind/actions/runs/41618618388) successfully; this does not explain PR151's retained failure.

## Remaining acceptance

F059 remains TODO. Enrolled-owner addition still needs the complete app producer/session drain, recoverable completed response, close-failure retry, fresh admission and quiet reconnect path. Capability negotiation, removal/rotation, provider retention/pressure and physical two-Mac acceptance remain open. This slice does not qualify GUI/TCC/keyboard behavior, uninterrupted 24-hour capture, energy/battery, production data-protection credentials, notarized distribution, complete v0 or a product ranking. All 83 feature statuses are unchanged.
