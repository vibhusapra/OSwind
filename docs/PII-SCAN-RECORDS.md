# Per-memory experimental PII import-check records

OSwind records which optional native PII import check ran for an admitted memory. A record describes a past processing step. It does not establish that PII is absent, satisfy a privacy acceptance policy, protect captured pixels/audio/video, or guard remote requests. The pinned model still has known misses and import scanning stays off by default.

This extends [experimental learned imports](LEARNED-IMPORT-PRIVACY.md). It covers normal JSON, version 1 collectors and saved Limitless API text responses through their shared import path. No new model download, provider call or background scanning is enabled.

## What is recorded

Schema 23 adds a library-owned `pii_scan_records` table with a foreign key to the source. It stores model ID, requested CPU/Core ML policy, threshold, check time, whether masking changed text, field/window/token counts, a coverage version, and a SHA256 binding to the admitted output. There is no separate pre-mask source, original-source digest or span list. Core ML is a requested execution policy; per-operator GPU/ANE placement remains unmeasured.

The fingerprint uses sorted-key UTF-8 JSON of the complete typed memory with favorites, embeddings/index model and media paths removed. It includes tags, speaker/diarization metadata, visual OCR, recap metadata, IDs and other typed content. It binds the admitted, potentially still imperfectly redacted output. The versioned coverage is `oswind-import-text-fields-v1`; it describes the original-source native/pattern import pipeline, not current capture or egress policy compliance.

The binding and record are prepared outside the import's writer transaction. Source data, record and projections then commit together behind the existing source/settings/root/activity checks. A record-write error rolls back the entire batch, including earlier source replacements. Canceled or refused scans create no records.

## Current, changed and unknown

`privacy-status MEMORY_ID` returns JSON, as do the read-only `memory_privacy_check` MCP tool, `/v1/memory-privacy-check?id=MEMORY_ID` authenticated loopback endpoint, and Python `client.privacy_check(memory_id)`.

- `recorded`: a supported record still matches the source snapshot. This is a processing record; `privacyAcceptance` remains false.
- `changed`: a content write/replacement invalidated the earlier record, or its content binding no longer matches. The earlier metadata is retained for reference.
- `notRecorded`: no local record exists. Legacy, captured and ordinary imported sources are not automatically inferred to have passed this model.
- `unavailable`: the stored record or supported content binding cannot be established. This does not fall back to a claim of a check.

A SQL trigger invalidates records on payload and source-column writes, including full replacements with identical content. Source-edit ABA cannot revive an invalidated record. The trusted favorite-only setter preserves the record inside its transaction because it changes no scanned text. Index-vector column writes do not invalidate text coverage. Tags and speaker edits invalidate it. Deletion, retention and full wipe cascade record deletion with the source.

The status lookup is one indexed source/record snapshot. Only a potentially current record causes a bounded source copy, parse and hash after releasing SQL. No model is loaded or downloaded. Search, list and normal capture insertion do not perform per-row scan-status hashing. The detail viewer loads status separately, clears it on selection/departure, and rejects late callbacks. A selected old/incomplete source cannot acquire a matching-current claim from another revision. This is snapshot metadata; callers making a later decision must read the current source/check again.

Receipts are bounded to 8 KiB; status content binding is bounded to 1 MiB. The smaller learned-import limits still apply to actual scanning. Unsupported/corrupt metadata never produces a recorded state.

## Imports, backups and trust

Plain JSON cannot mint a local check. The Memory interchange shape has no trusted scan field, and unknown claimed report fields are not used. A JSON export/import into another library creates no local check unless the import actually runs the scanner. An ordinary replacement invalidates an existing check even if its body is identical.

A full OSwind backup carries historical library records. Restore explicitly rebuilds their bounded rows after source restoration, verifies supported content bindings against restored text, and preserves valid current/invalidated states. Mismatched or unsupported claims are downgraded. Restoring a record does not rerun its model or update its original check time. Media path remapping does not change this text-only binding.

These are records under the library's control, not cryptographic attestations against someone who can modify the entire database or its backup. The JSON import boundary is enforced; a malicious owner of the complete database remains outside that claim. Schema 22 and earlier libraries gain an empty table without backfilling/inventing checks. Older binaries reject a schema 23 library rather than silently treating it as their own format.

## Verification status

[Qualification receipts](../benchmarks/pii-scan-records-v1.json) distinguish product commit `0839818` from fixture-only `d2ee1b1`. The initial 579-input frozen run retained three failing assertions that still expected schema 22: 1,211 passes, two skips and three failures. Only those three explicit version expectations changed to 23; every preservation/migration assertion and all product, tool and model inputs stayed unchanged. The entire suite then passed under a 581-input frozen manifest: **1,214 passes, two explicit skips, zero failures**. The initial failed report remains unchanged.

The unchanged product also passes **202 selected TSan checks, 202 optimized checks**, 16 offline Python SDK tests and eleven signed process groups. Those include 30 learned-import operations/eight native cases and 23 scan-record operations/two native CPU/Core ML cases. Coverage includes atomic rollback, favorite/tag/column invalidation, source matching, plain-JSON forgery refusal, deletion/wipe, full backups, unsupported records, late UI callbacks and model-free record reads. Signed known-email misses remain recorded with `redacted=false` and `privacyAcceptance=false`; recording a check adds no privacy-quality acceptance.

The separately staged schema 23 app and ZIP pass strict signatures, signature-normalized same-build payload checks and an exact 34-file extracted-tree comparison. The installed app remains byte-identical across its 15 captured files; no normal history or permission changes were used. Fourteen SwiftUI light/dark card snapshots and twelve AppKit Settings renders are retained. These are component renders and worker checks, not permissioned foreground/capture, VoiceOver or full desktop acceptance. Earlier independent native detach exit-16 failures remain release gates with unproven causes, despite this local pass and both parent PR #84 CI jobs passing.

Retained developmental failures include the initial async-XCTest-autoclosure test compilation, two assertions showing backup restore dropped records, and fourteen blank AppKit snapshots of SwiftUI layer text. Restore now copies/revalidates records explicitly; the card snapshots use SwiftUI's rasterizer. The initial full-suite schema-expectation failures are also retained. Product privacy-quality failures remain separately retained by the learned-import qualification.

## Remaining work

- [ ] Learned protection for live screen/audio admission, with persisted source and saved-policy checks.
- [ ] Actual image/audio/video treatment and retention/erasure verification.
- [ ] Explicit rescan/recheck controls for existing history; status reads never imply a rescan.
- [ ] Model/threshold acceptance on representative held-out desktop OCR, speech and metadata; no operating point is accepted.
- [ ] Remote egress protection and export policy; these records are descriptive and cannot serve as proof that content is safe to send.
- [ ] Profile operator placement, throughput and physical power. Competitive ranking and broad v0 parity remain open.
