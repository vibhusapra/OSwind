# Original-source production pattern masks

Production secret-pattern protection now matches every detector against the
original text, expands masks to complete composed characters, merges overlapping
or touching ranges, then replaces from the end. An earlier replacement cannot
hide a trigger needed by another detector. The six detection patterns and the
explicit redaction opt-out are unchanged.

The controlled fake input `sk-aaaaaaaaaaaaaaaaaaaa-password=OwnedOverlapSecret`
previously became `[REDACTED]=OwnedOverlapSecret` during real import/export.
An earlier key match consumed `password`, so the later password detector never
saw its trigger. An API-key prefix can similarly consume part of a private-key
header. The fixed result masks the complete overlapping range.

## Scope and ownership

The common `PrivacyPolicy.sanitize` path supplies capture text/metadata, imports,
transcript/replay text, saved answers/recaps and policy-filtered Markdown export.
`sensitiveRanges` supplies the same original-source pattern matches to explicit
learned inspection. New invariance tests compare their resulting masks.
Production pattern protection keeps its existing input scope; it does not inherit
the experimental PII inspector's smaller document/work budgets.

Compiled fixed regex instances are cached once; each matching source and mutable
replacement buffer remains local to the call. [Apple documents NSRegularExpression
as immutable and usable concurrently](https://developer.apple.com/documentation/foundation/nsregularexpression).
Invalid program-literal patterns fail initialization rather than silently
dropping a detector. This is a code-level invariant, not a measured speedup.

Detected text still suppresses raw retained audio and image/replay regions under
the existing admission rules. The fix does not implement region-perfect image
redaction or semantic audio privacy. The transcript/replay checks below use owned
metadata and synthetic/fake ASR, not physical screen/microphone acceptance.

The routine does not mutate existing libraries. Earlier records already stored
as `[REDACTED]=...` have lost their original trigger; rerunning these same patterns
cannot reliably identify the remaining value. No automatic historical-data repair
or default-library audit is claimed. Literal redaction markers alone are not proof
of a credential. Current-policy export protects raw owned source text, while an
exported copy remains independent of later source changes.

## Reproductions and development evidence

The unchanged preceding product fails **11 of 13 new cases**, with **123 failed
assertions**. Disabled-redaction and disjoint-pattern controls pass. The new cases
cover credential/private-key trigger overlap, trailing combining characters,
unchanged Unicode bytes, repeated redaction, input larger than the PII document
limit, 128 concurrent calls, actual JSON admission/export, transcript/audio
suppression, replay metadata and current-policy Markdown export.

After the fix, all **101 focused privacy/PII/export/audio cases pass**. A process
harness compares the exact preceding signed CLI to the current build: the old
binary mismatches eight text cases and leaves the fake value visible through
replay, Markdown and transcript text. The current build passes all 13 checks.
Both preserve the generated tone and suppress retained audio. Neither opens
normal history, captures a device or uses a real credential.

Initial fixture compilation uses the wrong region type; corrected fixtures use
the existing `TextRegion`/HEVC metadata contract. The first process harness stores
a Path in an operation-name JSON field and fails to serialize that receipt; the
fixed harness stores the actual command name. Both failed observations remain
retained. They are separate from the demonstrated production masking failures.

The public functional harness can run with only a new build:

```sh
python3 scripts/privacy-mask-smoke.py /absolute/path/oswindctl \
  --root /absolute/new-owned-fixture
```

For a causal before/after check, add `--baseline /absolute/old/oswindctl` and its
`--baseline-sha256 HEX`. A changed binary or missing baseline refusal fails the
check; expected old failures remain in the receipt rather than being counted as
passing current contracts. CI runs the current-build path without model downloads.

## Frozen qualification: privacy checks pass; terminal failure retained

[PR #77](https://github.com/vibhusapra/OSwind/pull/77) and the
[qualification receipt](../benchmarks/privacy-original-mask-union-v1.json) bind
product source `7621eb8`. **1,092 defined tests: 1,090 passes/two skips**, **154
selected TSan passes** and **113 optimized passes** complete with no failures.
Both real native PII backends preserve all 432 short-reference comparisons in
normal/TSan/optimized configurations. Precompiled framework/runtime internals
are outside TSan coverage; the skips remain physical system-audio opt-in and
unavailable visual admission.

The signed before/after process harness retains the old eight text mismatches
and three route failures, while all 13 current contracts pass. The standalone
CI route repeats those same 13 contracts; these are not 26 independent cases.
The actual signed CLI re-scores the same 72 authored validation examples with
exactly unchanged aggregate metrics: 14/48 fully covered values, 0/24 negatives
flagged. That corpus lacks the overlapping-trigger cases; unchanged aggregate
scores do not establish this repaired invariant or representative PII quality.
Thirty native-model CLI success/refusal/cancellation checks also pass.

The 34-file app/ZIP passes strict signatures, same-build normalized payload and
complete extracted-tree equality. Visual compatibility preserves 459/501 top1
and 498/501 top5/top10 with current model/corpus/scopes/index/reopen. Installed
and staged bytes remain unchanged. Final complete-command owned-executable and
current-artifact image inventories are empty. No installation/unscoped GUI occurs.

The ordered process qualification is **partial: 14/15 operations pass**. The
last held-reader terminal Ctrl-C trial returns CLI failure 1 with an attached
image and the public message `Cannot inspect encrypted disk attachments (hdiutil
exit 2)`. It fails before reaching the required busy-file refusal. The original
assertion remains strict. Normal recovery after closing the owned reader detaches
and preserves its note; that recovery does not convert the failed trial to a pass.

The native wrapper retains `terminationStatus` but discards `terminationReason`.
The reported 2 is not established as a normal exit versus an uncaught signal.
Earlier observed create/attach helpers already have process groups distinct from
the CLI; inherited foreground-group membership must not be assumed as the cause.
Retaining termination provenance and an owned reproduction are the next priority.
No force detach or favorable retry substitutes for that evidence.

A subsequent workflow-only change uploads owned pattern/terminal receipts even
when a later CI step fails. Product/test/script/model inputs remain unchanged
from the qualified product source; that workflow change has a separate CI head.
This fix does not establish complete PII detection, a learned operating point,
production learned admission, historical-data repair, desktop power or broader
competitive/release acceptance.
