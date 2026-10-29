# Sampled text observation spans

Implementation is in progress on top of source eadabc1 / PR #87. This source is not yet qualified. The first focused build exposed a private UI color reference; it was corrected before the next run. The current expanded focused run passes 132 checks, including evidence pinning; nine debug process groups / 26 operations cover CLI/HTTP/MCP/SDK, quiet portability, exact-boundary erase and an actual preceding schema 23 writer. Full native/model, sanitizer, optimized and signed package acceptance remains pending.

## What the range means

Automatic Accessibility-only capture can join repeated permitted observations of identical admitted text and window context. The source retains its first timestamp, last observed timestamp, sample count and largest observed gap. These samples do not prove continuous presence, attention, time spent or that no intervening change occurred. Manual captures remain separate points.

A span lasts at most 15 minutes and 1,000 samples. The accepted gap follows the capture cadence, capped at two minutes. A longer gap, wall/monotonic clock discontinuity, process/window-metadata/context change, blocked or unavailable context, pause, lock, sleep, permission loss or relevant settings change ends continuity. A later matching sample starts a new source. Indistinguishable windows with identical observed metadata/text can coalesce; no native window-identity attestation is made. No raw second AX body/title/URL cache is retained; the continuation stores bounded digests and source/time metadata.

## Storage and retrieval

Each extension must recheck full current context/privacy and the exact saved policy, active library root, activity reservation and cancellation gate. A final writer transaction compares the expected source/session/observation metadata before changing its payload. Concurrent edits or deletion cannot be overwritten. Current favorites/tags and embedding/vector/FTS bytes are preserved. An extension has a separate UI callback and does not enter source/entity/model indexing queues.

A sparse derived time projection serves sampled-text range queries without parsing source payloads on search. Query start is inclusive and query end exclusive; a last observed sample exactly at query start matches. Other legacy source kinds retain their source-start search semantics. Calendar counts and calendar browsing remain source-start based. External callers can request source-start-only behavior with CLI `--source-starts-only` or HTTP/MCP/SDK `sourceStartsOnly: true`.

Observation metadata participates in evidence revisions. Opening a result or consuming it for an answer atomically pins its current extent before model inference. An older visible result may advance only through a validated append of the same literal source/session; source edits still fail revalidation. Later automatic samples start a new source, so an answer or recap keeps the exact sampled extent it used. Saved references also pin their sources through SQL triggers, and the writer guard protects against late extension races. Pins contain source IDs, not duplicate text. Explicit source edits still invalidate dependent answers/recaps; deletion cascades pins. Quiet backup/restore reconstructs saved-reference pins. Text embeddings retain their independent content identity; sources without observation metadata keep their existing evidence hashes.

The logical library version is 24 so older writers refuse it. A quiet backup preserves sampled metadata with automatic services off. Plain JSON can carry authored sampled metadata; its presence is not proof of native capture or an absence of personal information. Metadata validation rejects impossible counts, dates, gaps and retained-media combinations. Pattern masking remains fallible.

## Work remaining

- [x] 132 focused store/controller/query/race/UI-model checks, including pin-before-inference and capture-after-pinning. Original compile and pre-fix regression failures remain retained.
- [x] Nine debug CLI/HTTP/MCP/SDK/portability groups and 26 operations. The actual preceding schema 23 writer drops unknown span fields; upgrading those sources preserves exact payload bytes and installs an empty projection.
- [x] Ten final light/dark owned component renders with sampled extents, capture health, source cards and mode guidance; native input/TCC acceptance remains separate.
- [ ] Owned archive migration/query/write work measurements and independent source oracle.
- [ ] Frozen full native/model, sanitizer/optimized, signed process/package checks.
- [ ] Updated comparison, feature ledger, qualified receipts and draft PR.
- [ ] Actual permissioned native text spans, representative application coverage and sustained power/cadence acceptance.

## Development performance probe

The first million-source probe retained a roughly 20-second migration and 1.6–1.7-second broad query regression. Supported pre-24 writers cannot encode observation metadata, so their upgrade now installs the empty projection without a payload scan; schema 24 cache repair still rebuilds from bounded sources. Time queries use the validated 15-minute maximum span to bound the timestamp index, then a CASE-gated sparse lookup, avoiding the large OR sort.

The corrected debug probe reports about 3 ms persistent MCP/SDK reads versus about 2.4–2.7ms for the preceding optimized build, with exact independent IDs. Open plus fixture verification is about 1.1 s versus the first 20-second result. These are warm development observations with different build modes and uncontrolled caches/background work. A paired signed optimized rerun is pending; no SQL-only, cold-start, energy or competitor ranking claim follows.

The initial frozen qualification was intentionally stopped after review found that metadata edits bypassed the sampled-payload size bound. An actual pre-fix regression case has three failed assertions: the oversized tag edit succeeded and removed time lookup coverage. Metadata writes now enforce the same span/record bounds before SQL; the rejected edit preserves its source and sparse projection. The interrupted manifest/logs, verified stopped handles and failed regression receipt remain retained. A fresh full qualification will use the corrected source.

A second frozen run passed all 1,281 defined full cases (three explicit skips) and 254 selected sanitizer cases (one skip), then was intentionally stopped during optimized compilation. Review found that an extending source could invalidate a visible result or answer in flight. Two pre-fix regression tests retain five failed assertions. The corrected consumer transaction pins the extent before reasoning/inspection, and capture continues in a new source. A newly added integration assertion initially counted only two captures while also storing a recap; it now checks two screen sources and three total records. These interrupted runs do not qualify the subsequent pinning changes.
