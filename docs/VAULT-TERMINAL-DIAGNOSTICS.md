# Owned terminal failure diagnostics

The [PR #100 hosted run](https://github.com/vibhusapra/OSwind/actions/runs/41185203985) fails an ordinary lock after an authored note with `hdiutil exit 16`. Earlier unit/native-vault/package stages pass; later process stages skip. Local normal and held-reader terminal flows pass, so the hosted failure's cause remains unproven.

The terminal smoke harness now saves `failure-*.json` before asserting a nonzero ordinary CLI result or unexpected terminal outcome. CI retains those files even when the step fails. The record identifies the exact CLI binary, original CLI exit status, output byte counts/hashes and any native exit/signal explicitly reported in the CLI error text. A CLI exit code is never converted into an inferred native result or a busy diagnosis.

`owned_vault_diagnostics.py` creates a fresh private fixture root and ownership marker. It checks the root identity, marker, package allowlist, session mount UUID, device/inode and matching owned-image inventory before asking `lsof` about that mounted filesystem. An unmounted directory cannot authorize a query against the host filesystem. Symlinks, root replacement, missing/changed context and unknown inventory refuse reader inspection.

Only descriptors matching both the recorded device and exact owned mount prefix are retained. Paths become `<owned-mount>/…`; unrelated image inventory and raw helper stdout/stderr are excluded. Credentials refuse persistence. Read-only helper capture is bounded to five seconds and 1 MiB combined output, with at most 256 reader records. Byte counts and hashes describe the captured prefix when output is clipped; clipped/expired output cannot supply reader records.

These are **after-failure observations**. A reported process is not proof that it caused the original failure, and an empty reader list is not proof that no reader exists. The helper neither unlocks/unmounts images nor retries a failed mutation, changes indexing/settings, uses sudo, or force-detaches. Diagnostic refusal records an error class without arbitrary exception text and preserves the original CLI/terminal failure. Existing normal recovery remains separate.

## Qualification

The [receipt](../benchmarks/vault-terminal-diagnostics-v1.json) covers three passing stages over 637 unchanged inputs:

- Nineteen offline contracts cover ownership/marker/symlink refusal, host-filesystem and unrelated-image refusal, exact device/path filtering, process/descriptor boundaries, path redaction, credential rejection, status provenance and helper time/output/count limits.
- A fresh normal encrypted fixture passes actual Ctrl-C create/unlock/lock, immediate recovery, original-history checks and final image absence.
- A fresh held-reader fixture preserves CLI exit1 and the CLI-reported `hdiutil exit16`. Its after-failure receipt observes the actual harness PID's SQLite database, WAL and SHM descriptors. Closing that reader allows normal recovery; the authored note survives and the image is absent.

Independent checks verify the frozen sources, log and PTY hashes, exact qualified CLI binary, expected reader PID/path, all owned image absences and unchanged installed app. All Swift/native/SDK inputs match PR #101's qualified source; no product rebuild or new full Swift-suite claim is made for this harness/CI-only change. An earlier 17-contract version and both real native flows also pass and remain retained.

Reproduce offline with `python3 scripts/test-owned-vault-diagnostics.py`. The existing `scripts/vault-terminal-smoke.py` commands use the diagnostics automatically; `--held-reader` additionally requires observing the known held SQLite reader before normal cleanup. Use a new explicit private fixture output root each time.

This supplies missing evidence for a future hosted failure. It does not fix or explain the retained PR #100 failure, qualify physical lock/power behavior, or promote any of the 78 delivery feature statuses. Full sync, native release and whole-product parity remain unfinished.
