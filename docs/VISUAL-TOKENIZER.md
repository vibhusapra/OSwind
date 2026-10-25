# Visual tokenizer byte fidelity and loading

This increment changes local loading of the pinned SigLIP2 tokenizer and fixes
two Unicode comparisons in its BPE frontend. Model weights, conversion recipe,
compute policies and image-vector identity remain unchanged. Performance
measurements and full release qualification are pending.

The existing generic `Hub.Config` JSON decoder probes several types at each
value. The pinned input has256,000 vocabulary entries and580,604 ordered merge
pairs. A full-test point observation showed about14 GB RSS; it is not an
isolated peak-memory or energy measurement. A native two-key regression also
shows keyed JSON decoding loses a canonically equivalent Unicode spelling.
The source vocabulary has61 additional entries in such equivalence classes.

The new bounded loader preserves exact keys through Foundation dictionaries
and handles the large integer vocabulary/string pairs directly. Small metadata
keeps the existing `Config` decoder, including token-tuple/null/Boolean behavior.
Foundation's JSON string parser also strips a leading U+FEFF: a rejected first
candidate retained255,994 entries. Every JSON string is now marked before
parsing and the exact marker byte removed afterward, preserving BOMs and leading
combining marks. No normalization or vocabulary-key rewriting is accepted.

Input is limited to36 MiB. Root/model objects, vocabulary/merge counts, token
bytes, metadata depth/nodes/encoded size and IDs are bounded. Cancellation is
checked before/after Foundation parsing and throughout the marker/conversion
loops. Foundation parsing and Core ML calls remain non-preemptible; this is a
cooperative cancellation boundary. No model/tokenizer download or Hub client is
constructed by this path.

The pinned Tokenizers module used canonical Swift String equality for BPE
merge keys, allowing a merge for `▁Å` to consume `▁Å` and fall back to bytes for a
nonexistent token. Literal space replacement also missed a space followed by a
combining mark. The local12-file [OSwindTokenizers target](../Vendor/OSwindTokenizers/README.md)
has two narrow patches: exact UTF-8 BPE key equality/hashing and literal String
normalizer replacement. All original Apache2.0 headers/license, full source
hashes, modified-file notices and a minimal patch are retained. Hub and Jinja
remain unchanged pinned package dependencies. Runtime notices ship with the app.

## Current evidence

All11 data/BPE cases and the complete17-case tokenizer/model-lifecycle selection
pass. The small canonical-key regression fails before the loader change; the
space/combining-mark regression fails before literal replacement. Rejected
parser/BPE candidates remain in the local evidence.

An independent pinned Rust/Python `tokenizers==0.22.2` preparation reads the
exact local source without weights or inference. Disable its source-declared
fixed padding before applying OSwind's truncate63 + EOS + right-pad64 contract.
All54 existing golden queries match that preparation. Another19 fixed inputs
and366 probes from all canonical-equivalent vocabulary classes give439 exact
ID/truncation/padding matches. These are tokenizer correctness checks, not
held-out visual retrieval accuracy or exhaustive Unicode/language validation.

| Complete source check | Value |
| --- | --- |
| Tokenizer SHA-256 | `cb9140fae3ac5122c972d37adf83e1248471a38147ad76f8215c8872c6fd8322` |
| Vocabulary count / framed SHA-256 |256,000 / `f57390f3a17769b135b2f59728f6c310d0835308f65843053208463f36955eda` |
| Ordered merges count / framed SHA-256 |580,604 / `4bdea648ea809879e4da3be6d25b28bffd60e5bbbeac784638e106b0c1145f67` |
| Independent439-query reference SHA-256 | `bfe39a039eb3b372433f8db1218d2bbf25d20db21659e70c644291e10e86e964` |

Vocabulary framing sorts by raw UTF-8 bytes, then hashes uint32BE byte length,
bytes and uint64BE ID. Each ordered merge hashes length+bytes for each of its
two strings. All entries are checked; counts and selected examples alone are
insufficient. The source input is explicitly pinned and licensed separately
from the application; no model weights are committed.

## Reproduce correctness

```sh
python3 scripts/check-tokenizer-vendor.py --upstream .build/checkouts/swift-transformers
uv run --locked scripts/prepare-visual-tokenizer-eval.py \
  --tokenizer-json /absolute/qualified-model/tokenizer.json \
  --output /absolute/new-reference.json
OSWIND_VISUAL_MODEL_DIR=/absolute/qualified-model \
OSWIND_TEST_VISUAL_TOKENIZER_REFERENCE=/absolute/new-reference.json \
swift test --filter 'VisualTokenizerDataTests|VisualEncoderTests'
```

Preparation requires a previously installed pinned local tokenizer. `uv` may
install the locked Python dependencies; add `--offline` when cached. The output
must be new. Ordinary CI runs synthetic tests/vendor integrity without model
downloads; complete model/reference checks require the two explicit variables.

## Paired workload plan

[Frozen plan](../benchmarks/visual-loader-plan-v1.json) fixes three authored
solid-color images, three queries and three alternating old/new pairs. The
CLI runs actual visual index/query/source validation/reopen in a fresh process
and library each time, requesting CPU+GPU. Baseline is the signed5aa58b9 build.
The harness records per-child CPU/maxRSS and awake/system clocks, retains failed
trials, refuses known concurrent build/test/CLI jobs and checks identical model,
corpus, recall, scope and reopened-source results. OS/Core ML caches and other
background activity remain uncontrolled. This is not cache-cold startup,
sustained desktop capture, measured physical power or a competitor comparison.
