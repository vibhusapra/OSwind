# Local answer-support baseline

The current product can return valid citation numbers and still give an obsolete fact, omit part of a question, or cite the wrong supporting record. This baseline retains those failures before changing prompts or model defaults.

The [frozen plan](../benchmarks/fixtures/answer-support-authored-v1.json) contains 16 fictional notes and 24 authored English questions covering lookup, paraphrase, negation, superseded assignments, combined questions, absent evidence, false premises and instructions embedded in sources. Each question runs once through the actual CLI AnswerEngine with Apple Intelligence and once with the installed local `qwen3:4b-instruct-2507-q4_K_M`. Both use the same Apple embeddings, exact retrieval and literal query interpretation. Earlier questions are not conversation history.

Runtime `49f259d` and its qualified release CLI are unchanged: all **700 committed runtime/test/dependency inputs** match the preceding storage qualification. The [mechanically reviewed receipt](../benchmarks/answer-support-baseline-v1.json), [input manifest](../benchmarks/answer-support-baseline-inputs-v1.json) and [raw archive](../benchmarks/answer-support-baseline-raw-v1.zip) retain every response, the exact seed operations, source identities/text, model digest, original harness failure and the explicitly authored pre-inference SQLite snapshot. There is no user history or credential in the dataset.

## Mechanical results

All **48 requests returned responses**. Both providers received identical retrieved source order for each question. The declared supporting documents were present in all **40 applicable question/provider cases**; eight absence cases have no required positive-support set. Every one of the **66 citation-number occurrences** is within the supplied source range. The product emitted **zero warnings**. Source, plan, runner and local-model stability checks pass, as do five altered-record rejection controls.

These counts verify execution and evidence admission. They do not measure whether a claim is supported or whether every question was answered.

## Concrete counterexamples

| Provider / question | Recorded facts | Retained response problem |
|---|---|---|
| Apple · combined project owners | Helios's old assignment explicitly says superseded; the current record assigns Devin. Harbor assigns Tess. | Answers Miri for Helios and Tess for Harbor despite retrieving the current Helios record. |
| Apple · Nimbus owners and audio | Imani owns integration, Chen owns documentation; a separate record says no raw audio is retained. | Answers the two owners and omits the requested audio-retention answer. |
| Apple · alleged completed launch | June 14 was rejected; June 18 is the approved target, with no completion proof. | Says June 18 was proposed but rejected and does not correct the completion premise. |
| Local Qwen · Atlas owner/region/capacity | Atlas owner is Leon; Helios owner is Devin. | Assigns Devin to Atlas and cites records that do not support that assignment. |
| Local Qwen · Nimbus owners and audio | Ownership and audio retention are in different records. | States the correct no-audio fact but its sole citation points to the ownership record. |
| Local Qwen · deployment backup | The current record explicitly names Priya as backup. | Declines to identify a backup while quoting that assignment. |

The receipt includes ten source-based observations, including qualified wording and completeness issues, and all 48 outputs rather than a selected scored subset. These are **Codex engineering observations against authored facts**, not independent human annotations or a semantic accuracy rate. No separate judge-model API was used. Correctly abstaining on absent facts does not excuse declining an answer that the retrieved record supports.

## Reproduction and limits

The first harness attempt successfully seeded all 16 notes, then failed before any answer generation because SQLite returned BLOB payload bytes where the fingerprinting code expected text. Its script, report and log remain retained. The continuation fixes that hashing path and reuses the original sources; it does not repeat successful seed writes or change questions, product prompts, model settings or source bodies. Successful runner/reviewer/publisher results are frozen.

Apple model asset bytes/version are not fingerprinted; macOS version is recorded. The installed Qwen digest matches before/after. A later read-only [Ollama running-model observation](https://docs.ollama.com/api/ps) reports `size_vram` and model size of 3,311,423,979 bytes with an 8,192-token context. That reported residency does not establish the processor used for every operation. Host activity/caches are uncontrolled; timings are diagnostic rather than comparative latency, power or battery measurements.

This small transparent authored set is not an unseen natural-user benchmark or a competitor ranking. Next work is a general evidence/prompt contract addressing supersession, project identity, requested-part coverage, premise correction and per-claim citation support, followed by a separate untouched evaluation. The baseline must remain unchanged. No runtime fix or quality improvement is claimed here. F031 and all 83 feature statuses remain unchanged; full sync, physical capture/energy and distribution acceptance remain separate.
