# Phrase and Boolean query scaling

In progress. The preceding [capture qualification](SYNC-CHANGE-CAPTURE.md) measures about 3.1 seconds for a broad required-phrase query over one million authored sources. This work removes unnecessary archive-wide eligibility construction from keyword retrieval and empty-model fallback. It is not a complete search-quality, semantic-scale, energy or competitor qualification.

## Behavior and invariants

The expression parser and ranking operands stay intact. Phrases remain required; unquoted words remain soft ranking cues; explicit Boolean precedence, negation, prefixes, cross-field body/speaker matches and metadata/time scopes remain enforced before the result limit. The query does not take a fixed top-K pool and discard ineligible records afterward.

Each ranked source checks content atoms against its stable `memory_fts_keys` key. It does not use the source table's implicit rowid, which can change during maintenance. Speaker operands retain their per-atom source sets, so separate labels or body text may satisfy separate parts of an expression. Speaker-heavy archives can still incur substantial set work; this is a remaining measurement requirement.

An actual semantic stage still materializes its full eligible set for vector scans and native masks. That work now happens after lexical retrieval and only when the selected model has vectors. The existence check reads the actual legacy, extra-vector and passage tables inside the search snapshot; a caller's stale coverage hint cannot hide another connection's committed vectors. Semantic searches with vectors retain their existing eligibility/mask path.

Before ranking, indexed necessary checks can prove an application, kind, favorite, tag, entity, speaker or time scope empty. These checks run in the current snapshot and keep no empty-answer cache. They do not replace the complete combined metadata/content predicate. A later committed matching source remains visible on the next query.

SQLite cancellation handling now covers lexical statements too. The handler is removed before cleanup. Only a scope that was actually materialized needs clearing. No schema/version, original source format, source mutation, public sync control or provider permission is introduced.

## Development evidence

- A read-only Python SQLite 3.54.1 diagnostic over the already authored million-source archive measures roughly 3.09 s constructing the temporary source-ID set, 0.70 s ranking with it and 0.50 s using candidate-local checks. The ordered top 100 agree in that diagnostic. These SQL-only, sequential, uncontrolled-cache observations use a different runtime from the product and are not release performance results.
- A test-fixture argument-order compilation error is retained; no tests ran in that attempt. The corrected first selection passes 52 cases with one explicit Metal opt-in skip.
- The expanded development selection passes all 63 cases. The actual 20k-vector Metal phrase workload executes, with exact top-ten agreement on its three queries. New cases cover high-ranked ineligible soft matches before a required hit, stable keys after source rowid changes and VACUUM, NUL-containing internal IDs, Unicode speaker renaming, mixed speaker/body Boolean rules, vectorless/empty-model fallback, stale coverage hints and cancellation recovery.
- The paired CLI fixture passes 36 keyword/local-hybrid observations against the preceding signed 793574e binary. Ordered hits, scores, complete returned sources, match/passage and warnings/model/strategy agree. Explicit keyword memberships and six invalid-syntax refusals are checked; original payload hashes remain unchanged. The first fixture was refused by the baseline public importer's existing NUL-ID guard; that failed setup remains retained. The public fixture now uses a normal ID, while the direct MemoryStore unit test retains NUL coverage.
- Five offline benchmark-admission contracts cover result identity/order/score/source changes, invalid results/timings, quantile definitions and unmarked/incomplete archives.

The first signed development pairing at source33bf9b7 passes all64 responses per size at100k and1m, with three timed rounds plus warmups. At1m, required-phrase median reported search time is2679→1209ms and empty-model hybrid3060→1301ms; rare lookups remain around1.5–1.7ms. Empty application scope still takes3824→2169ms, motivating the subsequent indexed empty-scope checks. These preflight results are retained and are not the final frozen measurements for the expanded implementation.

A second read-only diagnostic uses the actual system SQLite3.51.0: stable-key and direct ranked-rowid checks take1233/1239ms with the same100 results. Direct rowid substitution is therefore not pursued. This also explains why the PythonSQLite3.54.1 diagnostic cannot be used as a product speed claim. The updated development selection passes all86 cases, including impossible metadata scopes, later cross-connection insertion, text-observation time scopes and the20k Metal workload.

## Paired release protocol

`scripts/benchmark-keyword-scope.py` accepts only the completed, marked authored scale archive. It validates every original row and payload before cloning; each profile receives a separate APFS database clone. The retained input database and executable hashes must remain unchanged. No normal desktop history or live capture is opened.

The same query cases run in alternating baseline/candidate order, after one warmup per case/profile. Cases include broad phrases, Boolean exclusion, a rare soft cue, application scope, rare phrase/prefix, empty scope and local hybrid with no indexed model. Exact signatures include ordered results, scores, complete returned sources, match/passage, warnings/model/strategy and resolved scope; elapsed time is the only omitted result field. Independently checked source membership, explicit exclusions, rare first hits and empty scopes prevent result truncation from looking like an improvement.

The report retains every actual CLI response and raw timing. CLI process wall time and the product's reported search duration are separate. Median averages the center pair and p95 uses nearest rank. Small, warm same-device samples and uncontrolled filesystem caches/background activity do not establish a population tail, cold-cache behavior, capture/ingestion throughput, GPU efficiency, physical energy or ranking against another product.

Next gates: matched optimized measurements at 1k/100k/1m, independent source/result/timing review, full/sanitizer/optimized regression, signed package and public CLI/API/MCP/SDK checks. Broader semantic and speaker-heavy scale, capture quality, sustained power and complete user-facing sync remain open.

## Primary reference

[SQLite FTS5 ranking](https://www.sqlite.org/fts5.html#sorting_by_auxiliary_function_results) documents sorting through the hidden rank column. The product retains its existing weighted BM25 rank mapping and ordering; this change concerns eligibility work around that ranking path.
