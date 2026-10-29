# Read-only native launch signal diagnostic

This is a Foundation/terminal component analogue, separate from OSwind's vault
state machine. It runs only `hdiutil info -plist` or a synthetic Python sleep in
new private controlling PTYs. It changes no disk image, normal library, user
terminal, key, permission or power setting. Native inventory stdout is retained
only as a byte count/hash. Bounded stderr is saved privately on native failure.

On macOS, from a fresh repository output directory:

```bash
mkdir -p .artifacts/vault-signal-reproduction
swiftc benchmarks/prototypes/vault-signal/FoundationInfoProbe.swift \
  -o .artifacts/vault-signal-reproduction/foundation-info-probe
python3 benchmarks/prototypes/vault-signal/probe.py \
  --binary .artifacts/vault-signal-reproduction/foundation-info-probe \
  --root .artifacts/vault-signal-reproduction/trial-v1
```

The driver refuses an existing result root and freezes the probe binary hash.
Thirty cases are declared before execution: two helpers, five signal delays
(including no signal), three repetitions. Ctrl-C uses the PTY's VINTR byte;
credentials never enter the probe. Each completion preserves Foundation's
termination class, numeric status, output counts/hashes and observed process
IDs/groups/session. The harness exits successfully when the experiment completes;
nonzero native helper outcomes are observations, not hidden retries. Inspect
`results.json` and `summary.json`.

[All observations](observations-v1.json) retain two separate 30-case runs. The
initial run has 15 normal hdiutil exits and two SIGINT terminations among its
Python controls. The public-driver run has two hdiutil and one Python SIGINT
termination, all status 2. All observed child groups are their own PID. A group
observed after launch does not establish routing during launch. These are
unpaired timing-sensitive observations, not a failure probability or a diagnosis
of the older vault failure. The first diagnostic parser assumed newline-separated
JSON; PTY flushing dropped a separator between complete objects. The final parser
handles concatenated complete objects and refuses malformed data.

The Swift source is identical to the original successful component probe;
public-driver changes parameterize paths, protect the result directory, verify
the binary before each case, require completed probe processes and save a summary.
No complete OSwind cancellation, native action, power or performance acceptance
follows from this experiment. See [vault provenance](../../../docs/VAULT-TERMINATION.md).
