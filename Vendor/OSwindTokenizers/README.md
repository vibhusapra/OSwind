# OSwindTokenizers

This is the 12-file Tokenizers target from Hugging Face swift-transformers 1.3.5, commit48473106a93b2d8dfb114b82f0628ebbb71734e7. The original Apache 2.0 license and file headers are preserved. `provenance.json` records every original/vendored hash; `unicode-correctness.patch` records three narrow modified files. Hub and Jinja remain separately pinned package dependencies.

BPE merge keys now compare/hash exact UTF8 bytes. Swift String canonical equality otherwise lets a merge for `▁Å` consume `▁Å`, producing a nonexistent vocabulary token and byte fallback. A synthetic offline regression and 439 independently prepared SigLIP2 inputs cover this boundary. Literal String normalizer replacement also matches spaces before combining marks, preserving the pinned whitespace mapping. This does not establish exhaustive tokenizer/language/model accuracy.

ByteLevel now prepends one virtual space before regex splitting, matching the pinned Rust tokenizer. It preserves empty input and recognizes literal leading space even before a combining mark. Previously `a-b` gained extra virtual spaces before `-` and `b`; two assertions reproduce that failure. The experimental native PII input contract uses this BPE path; independent GLiNER/Rust references cover181 validation/boundary inputs. This does not select a production PII redactor.

The narrow local target makes the patch reviewable and avoids mutating SwiftPM checkouts or creating an external fork. When updating upstream, verify all provenance, rebase the small patch and rerun source digests, token references and model lifecycle checks. OSwind's explicit in-memory visual tokenizer and experimental PII tokenizer use this target. No automatic model/tokenizer download is added.
