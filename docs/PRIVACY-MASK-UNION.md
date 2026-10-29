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

Frozen full/race/optimized, signed package/process and unchanged authored
validation-baseline checks are recorded separately before publication. This
fix does not establish complete PII detection, a learned privacy operating point,
production learned admission, desktop power or competitive/release acceptance.
