# Portable sync records and typed export

Internal implementation work. F059 remains TODO. These types convert local canonical rows into portable data; they do not install a sync engine, acknowledge capture intents, publish packets, pair devices or admit a complete peer library.

## Supported data

| Canonical data | Portable representation and references |
| --- | --- |
| Sources | Original text/context/times, transcripts, visual frame metadata, sampled spans, tags/favorites, separately prepared media manifests and source-linked recap provenance. Local IDs, file paths, embeddings/model caches and search previews are excluded. |
| Conversations and turns | Titles/times, actual ChatPayload fields, global conversation identity and a portable filter with global entity identity. |
| Chat and recap citations | Owner identity, ordinal, score/match/passage and the exact immutable source-record content reference. Recap citation rows must agree with their owner's provenance. |
| Recipes and history | Portable prompt/schedule/scope; no AI configuration, endpoint, credential or activation fields. Historical revisions have an editor-origin namespace and either an exact definition reference or explicit unavailability for a pre-enrollment definition that was never retained. |
| Entities, aliases and mentions | Global entity/source references, curator state, canonical labels/keys, manual links and anchored automatic suggestions. Suggestions remain peer attribution; no completed local extraction/index state is imported. |
| Entity/project corrections | Versioned source reference and normalized legacy key or global project identity. |
| Evidence pins | Exact source-version reference. Actual chat/recap triggers create pin rows for ordinary sources too; these rows are preserved rather than restricted to sampled text. |

`SyncPortableExporter` handles all 13 canonical table schemas. It requires explicit identity, source-version, media, historical-recipe and audio-session binding resolvers. Primary storage classes and global lifetime must agree with the row. Duplicated source columns must match the complete Memory payload, including timestamp bits and original UTF-8 bytes. Local evidenceHash and entityRevision are separate resolver domains; they are not accepted as wire content hashes.

## Immutable versions and projection

Each canonical packet has a format/version, global origin/lifetime identity and one typed body. Its immutable reference authenticates the complete canonical packet bytes. Decode checks the expected identity/content, byte bound, format, body/table agreement and canonical encoding. Extra fields, alternate encodings and unsupported versions refuse. This prevents an unknown local-path/configuration field from being silently accepted as a transport extension.

Dependency validation requires the requested immutable content version. Falling back to a newer source or recipe refuses, even when the global object identity is unchanged. Citation ranges address the original complete source text in UTF-16 and must respect grapheme boundaries. Mention surfaces require exact original UTF-8 bytes. Alias kinds must match their entity; project corrections require projects. Direct self-citing recaps refuse; complete cross-record cycle detection remains a transaction-processor requirement.

`projectedMemory` rewrites source references through explicit local version bindings and accepts only an explicitly admitted set of local media paths. Rewriting recap IDs can change local evidenceHash even when wire evidence is unchanged. The eventual persistent version catalog must therefore bind wire versions to actual local versions; a global object ID alone is insufficient. Imported audio-session projections also require their original explicit session binding when re-exported, so they are not hashed into a new session. Raw local session IDs are hashed with their origin, never parsed as trusted global tokens.

Recipes project disabled, with this device's default AI configuration and remote processing disabled. A peer's running history projects as interrupted and confers no local run claim. Absolute/file/traversal model locator attribution in transcripts becomes `peer-unspecified`; model labels are never executable locators. These conversions do not replace current privacy checks on recorded text and metadata.

## Media

A record remains bounded to 128 MiB. Asset manifests contain role, whole-asset digest, total size and ordered authenticated chunk references, without names or paths. Full chunks are 8 MiB, the final chunk may be smaller, and 4,096 chunks bound one asset to 32 GiB. Streaming verification retains one returned chunk, checks each chunk's digest/length and verifies the full concatenation digest; cancellation is checked between chunks. Source preparation must supply every retained media role exactly once, and role ordering is deterministic.

These are metadata and byte-integrity checks. Safe filesystem staging, actual image/audio/video format admission, current-policy checks, encrypted cache retention, epoch fencing and transactional adoption are still required. The authored 136 MiB repeated-chunk fixture establishes integrity/layout behavior beyond the record limit; it is not disk/provider throughput, app memory, energy or competitor performance evidence.

## Development evidence and remaining work

The first real-row run fails one of eight cases because it incorrectly requires every pin to refer to sampled text. The retained fix follows the actual canonical triggers; no pin row is skipped. Expanded tests exercise every table, actual source/turn/recipe payloads, exact canonical-row preservation, immutable version substitution, malformed rows and metadata, local-authority exclusion, explicit audio-session round trips and typed recap reconstruction in a second owned library. Qualification results are recorded in the delivery ledger and receipt.

The [development receipt](../benchmarks/sync-portable-records-development-v1.json) records all 24 new cases passing in the full, selected sanitizer and optimized builds. The initial frozen full run has 1,441 passes, seven skips and one failed existing indexed-retrieval ranking assertion (row-134 missing from the exact top five). All 32 unchanged isolated replays pass; their TMPDIR watcher captures no authenticated graph, and the original failure remains unexplained. The original test and NativeANN source bytes match the base commit. The replay driver checks its test-binary hash during the run, but those historical binary bytes are not retained after later builds. These limits are explicit; no repaired broad gate is claimed.

The selected follow-up includes the original indexed-retrieval class: sanitizer and optimized each pass 208 cases with two worker-entry skips. All 12 follow-up stages pass over 837 unchanged inputs. Independent review checks strict signatures, normalized code payloads, every extracted ZIP file, all five traced image absences and the unchanged installed app. The earlier pin-admission failure and a report-preflight pluralization/startup failure are retained; no follow-up tests run in the failed startup attempt. Passing follow-ups do not supersede the failed broad run.

Subsequent [native-index work](NATIVE-ANN-INTEGRITY.md) retains actual graphs and reproduces the omission class independently of this codec. Serial native insertion and a new cache generation pass the original ranking assertion, all 24 portable-record cases, a new frozen full gate and 32 scoped replays. The specific old row-134 graph remains unavailable. The preceding failed run remains historical evidence; the later correction has its own [receipt](../benchmarks/native-ann-integrity-v1.json).

The complete feature still requires a durable wire/local version store, all typed incoming graph/media adapters, dependency-aware projection/collision handling, current-row/privacy/epoch revalidation and capture/bootstrap-to-journal processing. Source versions must not keep erased evidence available through a citation. Cache/backpressure and source-body duplication costs need measured scale qualification. Trusted enrollment, erasure/wipe epochs, compaction, native/CLI workflows, cross-SDK canonical encoding, provider behavior and two-Mac acceptance remain in [PERSONAL-SYNC.md](PERSONAL-SYNC.md).

The required [durable version store and local bindings](SYNC-VERSION-STORE.md) are now component qualified with their own source/erasure, session/run/recipe, process-death, bounded scale and staged package evidence. The remaining complete processor and workflow requirements above stay open; this follow-up does not enable sync.
