# Responsive library lifecycle status

Source `b2c520ce97d482933b3b4a5ef61f8178a8c6fd2d`, schema 22. [PR #68](https://github.com/vibhusapra/OSwind/pull/68).

Long imports hold the SQLite mutex while writing and generating embeddings. Main-actor guards, including the desktop shortcut, ask `MemoryStore.isClosed` before starting work. Previously that status read acquired the same recursive mutex and could wait for the entire writer.

The connection pointer now has a separate short lock. Its getter and setter synchronize the single authoritative pointer, including SQLite's opening out-parameter, ordinary close and both restore teardown paths. `isClosed` reads that pointer without acquiring the SQL mutex. No duplicate closed flag is maintained. Queries still acquire the SQL mutex for their full lifetime; media/volume leases and native close behavior remain unchanged. Lock ordering is SQL mutex then short connection lock; status readers release the short lock without acquiring the SQL mutex.

A pending close continues to report open until native close succeeds. A failed native close retains the pointer and reports open; after the held statement is finalized, a retry closes it. A false result is only an instantaneous lifecycle observation, not a lease allowing unsynchronized SQL or an assurance that the connection will remain open.

Seven owned-library cases cover:

- A held uncommitted writer: status completes before release while a SQL reader remains blocked, then reads the committed source.
- A close queued behind that writer: status remains responsive and open, close remains incomplete, and the committed note survives reopen.
- Four concurrent status readers across closing, with no open transition after observing closed.
- Ordinary/repeated close and refusal of queries/writes afterward.
- Native close failure with an actual outstanding SQLite statement, followed by successful retry.
- Sealed restore and discarded restore connections.

Against the preceding implementation, both held-writer status probes fail their one-second early-completion assertion; the other four initial cases pass. All seven expanded cases pass after the change. An initial fixture compile failure is retained separately. These are causal synchronization tests, not measured desktop input latency or a performance percentage.

[Qualification](../benchmarks/nonblocking-library-state-v1.json) passes all 938 defined cases: 937 passes, one physical-audio skip, zero failures. All 177 selected app/lifecycle/backup/vault Thread Sanitizer cases pass without race reports, and all 11 ordered operations pass, including the signed app/ZIP payload proof, actual encrypted migration, ordinary/indexed API/MCP, recaps, backup and legacy-vault processes. Installed and staged bundle bytes remain unchanged after checks. Both frozen-source CI jobs pass (run 40779889309). Later documentation revisions have separate runs. The first final-audit assertion retained no diagnostic values; a suspected shell self-match was not reproduced. A later audit finds that macOS truncated `comm`, so its basename filter could exclude live processes; the process-absence portion is withdrawn. Full-command-path filtering later finds no owned GUI and records the expected current follow-up driver/test, without proving earlier point-in-time absence. Image inventories and unchanged-artifact hashes are independent and remain accepted. The initial assertion cause remains unproven. Physical desktop/shortcut latency during a long import, device sleep/wake, power use and whole-product competitor benchmarks remain separate gates. The current 1,000-note import takes 26.36 seconds, alongside prior unpaired observations of 25.82 and 97.34 seconds. The authored input and every stored vector match; host/framework/cache state is uncontrolled and the current CLI bytes differ. These observations do not establish a code regression or an improvement from this change.
