# Native vault failure diagnosis and closing state

PR #73's later CI head `c8aa5cc` fails the owned rapid-lock test in
run40824503723/job123284316910. Earlier source CI and newer source/local tests
pass, but the old code discarded the failing native exit/status/output and
reported every normal-path detach error as “files are in use.” The historical
cause remains unproven. A passing retry does not repair that receipt.

## Product behavior

Native attachment inventory, encryption and APFS-volume queries now distinguish
nonzero tool exits from malformed successful output. A missing encryption flag
is unknown, rather than evidence that an image is unencrypted. Failure messages
include operation/tool/exit status without raw native text, paths, UUIDs or
credentials. Error reflection and the retained summary contain only fixed
operation names, counts and SHA256 output digests.

An exit code is not an attachment observation. After a failed normal detach or
the existing moved-mount fallback, fresh observation can find the owned image
already gone. The closing policy then still requires two consecutive fresh
absent observations, with package/manifest/image identity checked around IPC.
Changed or unknown identities, unavailable inventory and cancellation cannot
become a locked result. A still-attached image preserves the failure and closing
state. The existing moved-mount fallback uses only normal unmount/detach calls;
no force flag or busy retry is introduced.

The policy is separated from native IPC so complete status/observation
interleavings can be tested: failed action/already absent, one absence,
successful exit/still attached, moved mount, failed unmount, incomplete final
detach, replacement identity and cancellation. The real driver retains its
native kernel/device/UUID checks and supplies fixed native commands.

## Owned diagnostic observation

Public LibraryVault construction installs no observer or descriptor probe.
Internal owned fixtures can capture a bounded nonsecret diagnostic stream.
Create/attach stdin credential calls never enter that observer. Inventory,
encryption and device stdout are omitted because they can contain other image
metadata. Mutation stdout and native stderr excerpts are limited to suffixes;
full byte counts/hashes distinguish truncation from complete output.

The rapid fixture retains stage labels, native results/durations and up to512
events. Before a mutation it snapshots descriptor metadata from its own process
and retains only fixture paths or the verified mounted filesystem device. It
does not read file contents or inspect another application's descriptors. The
snapshot is not atomic and can race a concurrent close. No claim of complete
system-reader discovery follows from an empty own-process snapshot.

Trace export checks for the generated fixture credential before printing or
writing. Normal public calls emit no trace. CI uploads these owned trace files
even if a later step fails. To retain them locally:

```sh
OSWIND_TEST_NATIVE_VAULT=1 \
OSWIND_TEST_VAULT_TRACE_DIR=/absolute/new-owned-traces \
swift test --filter NativeVaultDetachSettlementTests
```

The controlled held-reader test opens one raw handle to its synthetic SQLite
file. It observes native exit16 and “Resource busy,” confirms that the image
remains mounted/closing, closes the reader and recovers normally with the note
intact. This validates the diagnostic positive control; it does not establish
that the historical CI failure was EBUSY or identify an external system reader.

## Development observations

Eight serial preceding diagnostic runs complete64 normal detaches /832 observed
calls without a nonzero exit. The original CI failure does not reproduce there.
The first path-filtered descriptor collector misses the known held reader and
fails its assertion; matching the independently verified filesystem device then
captures it and observes no mounted own-process handles in the normal cycle.
The initial held-reader fixture's missing `session(info:)` argument is retained
and corrected. Earlier trace suffixes represented body completion rather than
XCTest assertion success; final trace names use `completed` / `exception`.

The current focused prequalification has46 passing cases before two additional
cancellation cases. Final frozen-source full/race/release/native-process and
package observations are recorded separately. The new result-aware state policy
repairs a logical error class; it does not prove the old CI counterexample's
cause or claim general encrypted-library release acceptance. Native GUI/TCC,
busy-terminal inventory failure, physical power, broader parity and the prior
default-library activity audit remain open.
