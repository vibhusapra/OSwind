# Paired ordinary vault status observations

[Result](status-observations-v1.json) retains all 44 calls: 22 alternating AB/BA
pairs, with the first two pairs declared warmups before execution. Measured 20
calls per binary use a single detached, synthetic encrypted APFS package.
All outputs match and the note survives a final normal reopen/lock.

Build the preceding source 1de936a and candidate 7e21e0f in separate fresh checkouts,
stage/sign each app, and record their actual CLI SHA256 hashes. New builds need
not be byte-identical to the published binaries; treat them as a new experiment.
Then, from the repository root:

```bash
python3 benchmarks/prototypes/vault-query/measure-status.py \
  --candidate /absolute/path/to/candidate/oswindctl \
  --candidate-sha256 CANDIDATE_SHA256 \
  --baseline /absolute/path/to/preceding/oswindctl \
  --baseline-sha256 BASELINE_SHA256 \
  --root .artifacts/new-owned-status-observation
```

The script refuses an existing output root, verifies bytes before each measured
command, retains failed runs and never changes a user library, Keychain,
permission or power setting. The random passphrase stays in memory/stdin.
Root creation and normal encrypted setup/recovery are outside measurement.
Each command includes process startup and native system queries. CPU samples
are OS-reported waited-child user+system deltas; no GPU or watts are measured.
Binary hashing before each call warms files for both versions.

Published host: Apple M5 Max/macOS 26.6.2. Median elapsed 64.12→66.49 ms;
median paired difference +1.72 ms. This uses uncontrolled host/cache conditions
with paired command ordering, not causal attribution, isolated fence cost,
desktop capture throughput or competitive ranking. No latency threshold is
retrofit to the samples. See the [query-recovery contract](../../../docs/VAULT-QUERY-RECOVERY.md).
