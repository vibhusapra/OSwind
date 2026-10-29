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
windows/1,920 framed tokens; both cover all three authored phone values. These
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

Frozen full/race/optimized, signed CLI/package and compatibility qualification
is recorded separately before publication. No old failure is replaced by a
later favorable observation. The 144 reserved PII test predictions remain
unopened; production privacy policy, media handling and revision fences remain
separate implementation/acceptance work.
