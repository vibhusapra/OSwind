# Complete bounded document inspection

`PIIInspector.inspect` and `oswindctl pii inspect` now plan overlapping model
windows for a complete bounded document. CPU uses up to 512 framed tokens;
Core ML uses the existing fixed 128-token graph. The pinned graph, tokenizer,
runtime and model setup recipe are unchanged. Neither backend truncates input
to its first window. Learned production recording/ingestion/egress policies
and representative privacy-quality acceptance remain open.

## Coverage and limits

The document must fit all of these limits: 131,072 UTF-8 bytes, 32,768 Unicode
scalars, 8,192 original model words, 1,024 bytes per word, 256 windows and 65,536
total framed tokens. Core ML's total includes padding. A word or complete
composed-character group that cannot fit one model window refuses the entire
document. A threshold strictly between zero and one is still required; 0.5
remains an example rather than an accepted privacy operating point.

Every original word is tokenized once and covered. Windows overlap by up to 16
words, capped at half the preceding window; a composed-character boundary or
an expensive next word can reduce overlap. A decomposed character or emoji
sequence is never split at a window seam. Original whitespace and global UTF-16
coordinates remain intact, including gaps longer than a model window's former
source-character limit. Token cost depends on words rather than whitespace.

The complete plan is bounded and checked before inference. Each result must
match the model, exact window bytes and document/word-position ID. A hash of
repeated window text alone cannot admit output from a different position.
The final source digest covers the entire original document.

Overlap provides context; it cannot guarantee detection of an arbitrarily long
entity, a secret absent from the model's learned vocabulary, or a context-sensitive
boundary case. Successful inspection is not proof that all PII was removed.
See [the existing quality results](PII-EVALUATION.md).

## Masks and ownership

Each window decodes in original global coordinates. Duplicated range/label
detections retain their highest confidence; differing overlapping detections
remain in the union. There is no global flat-span competition that can discard
a sensitive range found in another window. Whole-grapheme mask union is applied
to the original document, alongside secret-pattern ranges computed on the same
original bytes. No earlier learned mask can hide a later pattern trigger.

The existing FIFO lease covers planning and every window of one document.
Queued requests cannot interleave their windows. Cancellation, shutdown, an
invalid plan, any malformed/nonfinite/foreign window or exceeded work/span
budget refuses the complete result. In-flight planning/native work is joined
before session destruction. No partial success or regex-only fallback returns.
Retention begins after the whole request releases its lease.

JSON retains the existing fields and adds `windowCount` and `framedTokens`.
The model ID includes `windows-v1` to identify the changed inspection contract.
The span list can contain overlapping detections; the mask list is merged.
The CLI remains history-free and has cooperative SIGINT cleanup during asset
verification/model loading/planning/inference. A second Ctrl-C uses the existing
immediate-exit behavior and can leave a temporary runtime-code snapshot.

## Development evidence

The first focused suite passes 53 cases; the expanded suite passes 55. Real
CPU/Core ML preserve all 432 short-input validation comparisons across the
existing 72 sources/three thresholds. The existing 181 tokenizer references
also check window framing against the original encoder. A repeated authored
860-word document yields three CPU windows/1,223 framed tokens and 15 Core ML
windows/1,920 framed tokens; both cover one known authored phone value at all three positions. These
are compatibility/functional observations, not representative privacy quality,
causal speed, physical GPU placement, energy or competitor evidence.

The first CLI cancellation observer assumes Foundation honors a private
`TMPDIR` and misses the snapshot. A separately recorded exact-child descriptor
probe finds the runtime in the user temporary directory despite that override.
The revised observer inspects only its exact child PID's mapped/retained runtime
path. Thirty debug CLI checks pass, including CPU/Core ML SIGINT returning 130,
empty result streams and removal of their observed runtime snapshots. The
original failed observation remains retained. The observer proves native runtime
preparation, not a particular inference instruction being in flight.

## Frozen qualification and outstanding production failure

[PR #76](https://github.com/vibhusapra/OSwind/pull/76) and the
[machine-readable receipt](../benchmarks/pii-document-windows-v1.json) bind the
implementation to source `3890d6d`. **1,079 defined cases: 1,077 passes/two skips,
95 selected TSan passes and 88 optimized PII passes** complete with no failures.
All **15 ordered operations** pass. The skips are physical system-audio opt-in
and unavailable visual admission; precompiled native/framework internals are
outside TSan coverage. Both actual backends preserve all 432 short-reference
comparisons in normal, TSan and optimized configurations.

The signed CLI passes **30 real-model checks, 19 offline inspection refusals,
11 offline setup refusals and two managed-cache long-document checks**. CPU and
Core ML native-preparation SIGINT each return 130 with no result and remove their
observed runtime-code snapshot. The final ordinary/migration, SIGINT and normal/
held-reader terminal vault checks pass. The 34-file app/ZIP passes strict
signatures, same-build normalized payload and complete extracted-tree checks.
Visual compatibility preserves 459/501 top1 and 498/501 top5/top10 with exact
current model/corpus, scope/index/reopen. Installed/staged bytes remain unchanged;
final complete-command owned-process/current-artifact-image inventories are empty.
No installation or unscoped GUI launch occurs.

CPU and Core ML use different long-document window boundaries and can produce
different detections. Matching short references and the repeated authored phone
example do not establish equivalent or representative long-document quality.
No old failure is replaced by a later favorable observation. The 144 reserved
PII test predictions remain unopened.

A subsequent controlled production-admission probe finds a separate pattern
masking failure on the same immutable signed CLI. For the fake input
`sk-aaaaaaaaaaaaaaaaaaaa-password=OwnedOverlapSecret`, production import/export
retains `[REDACTED]=OwnedOverlapSecret`: an earlier regex replacement removes the
later secret trigger. Explicit inspection masks the whole example from original
source ranges. This receipt retains both outputs and their source/binary hashes.
The production original-source pattern-union repair is the next priority.
The passing suite does not cover this newly reproduced contract; no normal
history audit, automatic repair of older records or privacy-release acceptance
is claimed. Representative hybrid quality, learned production admission, media
treatment and privacy/record revision fences remain separate work.
