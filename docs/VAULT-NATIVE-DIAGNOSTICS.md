# Native vault failure diagnosis and closing state

PR #73's later CI head `c8aa5cc` fails the owned rapid-lock test in
run 40824503723/job 123284316910. Earlier source CI and newer source/local tests
pass, but the old code discarded the failing native exit/status/output and
reported every normal-path detach error as “files are in use.” The historical
cause remains unproven. A passing retry does not repair that receipt.

## Product behavior

Native attachment inventory, encryption and APFS-volume queries now distinguish
normal exits, signal/unknown termination and malformed successful output. See the newer [termination provenance qualification](VAULT-TERMINATION.md). A missing encryption flag
is unknown, rather than evidence that an image is unencrypted. Failure messages
include operation/tool/termination class/status without raw native text, paths, UUIDs or
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

The rapid fixture retains stage labels, native results/durations and up to 512
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
file. It observes native exit 16 and “Resource busy,” confirms that the image
remains mounted/closing, closes the reader and recovers normally with the note
intact. This validates the diagnostic positive control; it does not establish
that the historical CI failure was EBUSY or identify an external system reader.

## Development observations

Eight serial preceding diagnostic runs complete 64 normal detaches /832 observed
calls without a nonzero exit. The original CI failure does not reproduce there.
The first path-filtered descriptor collector misses the known held reader and
fails its assertion; matching the independently verified filesystem device then
captures it and observes no mounted own-process handles in the normal cycle.
The initial held-reader fixture's missing `session(info:)` argument is retained
and corrected. Earlier trace suffixes represented body completion rather than
XCTest assertion success; final trace names use `completed` / `exception`.

The first trace export leaves synthetic temporary paths in escaped JSON. A
test-only follow-up matches JSON-escaped roots and the POSIX `realpath` spelling.
Its initial sort expression exceeds the Swift type-checker budget and is split
into typed steps. The next four-case suite passes, but a separate export audit
finds `/private<owned-fixture>`: Foundation's resolved `/var` differs from
`F_GETPATH`'s `/private/var`. That failed audit is retained. A real-filesystem
regression now verifies the kernel spelling before either export or printing.

## Frozen qualification

[PR #75](https://github.com/vibhusapra/OSwind/pull/75) has a
[machine-readable receipt](../benchmarks/vault-native-diagnostics-v1.json).
Product source `4594e94` passes **1,052 defined cases: 1,050 passes, two skips,
zero failures**; **128 selected TSan passes**; **48 optimized vault passes**;
and all **15 ordered operations**. The skips are physical system-audio opt-in
and visual admission under unavailable session conditions. TSan does not
instrument precompiled native/framework internals.

Normal, instrumented and optimized native fixtures each retain 154 native calls,
12 normal detach calls and one expected held-reader exit 16. Four additional
optimized rapid trials retain 416 native calls/32 normal detaches with no
nonzero exit. Counts include initial and final closing. Each rapid fixture
checks all six saved notes and independently confirms no attachment after lock.
These functional repetitions do not establish failure probability or latency
improvements under a desktop workload.

The signed CLI passes 13 ordinary vault/migration checks, two observed-helper
SIGINT trials, and controlling-PTY Ctrl-C during create/unlock/lock. All ordinary
interruptions return 130 with no image attached and preserve immediate recovery.
The held-reader terminal trial returns failure 1, preserves the attached closing
state and busy message, then recovers normally with history intact. The older
terminal inventory-error counterexample remains unexplained; this passing
trial does not replace it. No old-writer check was requested in this run.

The 34-file app/ZIP passes strict signatures, same-build normalized raw/signed
payload checks and complete extracted-tree equality. The signed CLI preserves
459/501 top 1 and 498/501 top 5/top 10 on the existing 100-image fixture, including
scope/index/reopen checks. Installed and staged bytes are unchanged; final
complete-command process inventory and current-artifact image inventory are
empty. No installation or unscoped GUI launch occurs.

Fixture-only source `193287c` leaves product/vendor/package/model/script/workflow
inputs identical to `4594e94`. Its **five focused cases pass in each normal,
TSan and optimized configuration**, and separate exported-file audits verify
owned paths use `<owned-fixture>`. This follow-up is separate from the earlier
full-suite receipt. Raw earlier trace/audit failures remain local; the public
receipt contains hashes and bounded summaries.

The new result-aware state policy repairs a logical error class; it does not
prove the old CI counterexample's cause or establish encrypted-library release
acceptance. Native GUI/authentication/TCC, physical power, broader parity and
the prior default-library activity audit remain open.
