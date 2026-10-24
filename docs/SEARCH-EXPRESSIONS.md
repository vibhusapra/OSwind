# Required phrases and Boolean content search

Ordinary questions retain soft token ranking. Quotes and uppercase Boolean operators add required conditions before keyword or vector ranking; changing the search mode or falling back from an unavailable embedding model never removes those conditions.

| Query | Behavior |
| --- | --- |
| `archive launch` | Ordinary ranked cues; either word can retrieve a source. |
| `"archive launch"` | Requires that adjacent token phrase. |
| `owner "archive launch"` | Requires the phrase; `owner` remains a ranking cue. |
| `"archive launch" "Friday deadline"` | Requires both phrases in the same source. |
| `alpha AND beta` | Requires both words, using the existing prefix matching for unquoted words. |
| `alpha AND (beta OR gamma)` | Requires alpha and either beta or gamma. |
| `alpha NOT beta` | Requires alpha and excludes beta prefixes. Use `NOT "beta"` to exclude only the exact token. |
| `(alpha OR beta) NOT gamma` | Either positive branch is allowed, with gamma excluded. |
| `"archive launch" app:Mail yesterday` | Intersects content conditions with application and capture-time filters. |

Straight and curly double quotes work. A phrase uses the existing Unicode FTS tokenizer: case, diacritics, whitespace and punctuation follow its normalization. The last phrase token is exact, so `"Frame 21"` does not admit `Frame 210` or `Frame number 21`. This is a token phrase, not a byte-for-byte string or regular expression. See [SQLite's FTS5 reference](https://www.sqlite.org/fts5.html).

Positive content operands may match a source's title, application, extracted text or recording-local speaker labels. A phrase cannot span separate FTS columns, different speaker-label entries or separate source records. Individual AND operands can match different fields of the same source. Source URLs are not a separate keyword column. Record-level app/date/kind/tag/favorite/speaker filters continue to intersect the result.

Uppercase `NOT` binds most tightly, then `AND`, then `OR`. Adjacent operands in a Boolean expression imply AND. Each OR branch must include a positive word or phrase; purely negative searches such as `NOT alpha`, or `alpha OR NOT beta`, are rejected. Quotes protect an operator when it is content, as in `"AND"`. Lowercase conjunctions keep their earlier ordinary-question behavior.

Metadata/date scopes apply outside the content expression: write `(alpha OR beta) app:Mail`. An OR of application/date scopes is not supported. Quote date words when they are content, such as `alpha AND "yesterday"`.

## Escape hatch and errors

Turn **Query filters** off, pass CLI `--literal`, or send API/MCP `literal: true` for ordinary token ranking without date, required-phrase or Boolean interpretation. This preserves the existing literal option's behavior; it is not exact-character or regex matching.

Malformed quotes, missing operands, unmatched Boolean groups, unanchored negative branches, NUL characters or excessive input fail before embedding/model requests. There is no silent broadening to unfiltered search. HTTP reports status 400; MCP reports a tool result with `isError: true`. The UI previews the error and shows a required-phrase/Boolean badge for valid constraints.

Bounds are 4,000 query characters, 64 Boolean atoms, 12 nested groups/NOT operators and 32 required phrases without Boolean syntax. These bounds are validated before model inference. Regex, NEAR, arbitrary SQL/column syntax and Boolean combinations of metadata scopes remain future work.

```bash
oswindctl search --mode keyword '"archive launch"'
oswindctl search 'alpha AND (beta OR gamma) app:Mail'
oswindctl search --literal '"archive launch"'
oswindctl ask --provider evidence '"archive launch"'
```

Ask applies constraints from the **current** question. Earlier questions can help rank the subject of a follow-up, but their old quotes, Boolean operators and date/app filters cannot become new constraints. Saved questions remain readable, and source-revision guards continue to control publication.

Replay opening prefers a frame containing the required positive phrase over a numeric-prefix sibling or a weaker semantic passage. For example, Frame 21 wins over Frame 210. This frame preference is a text heuristic; the backend FTS predicate remains authoritative for source eligibility. Filters operate at source/clip granularity, and date bounds still use clip start time.

## Implementation and verification

Eligible IDs are materialized once in a private disk-backed SQLite temporary table within the search snapshot. Candidate validation uses indexed membership lookups. The Metal mask cache key includes the expression fingerprint, metadata predicates, source nonce and vector sequence; switching phrases or editing content cannot reuse an incompatible mask. Temporary IDs are cleared after the operation. SQL cancellation clears the progress handler, leaves no published result and preserves the next query's connection.

```bash
swift test
swift test --sanitize=thread --filter 'SearchExpressionTests|StoreTests|IndexedRetrievalTests|QueryScopeTests'
OSWIND_TEST_EXPRESSION_METAL=1 swift test --filter SearchExpressionTests/testMetalExpressionMasksAcrossQueriesAndUnreplayedContentChange
scripts/build-app.sh release
python3 scripts/search-expression-smoke.py dist/OSwind.app/Contents/MacOS/oswindctl
```

The generated 20k-vector Metal workload checks exhaustive float32 top-10 equality across phrase switches and an intentionally unreplayed content update. Its first worktree diagnostic took 2.16–2.66 seconds because FTS subqueries were recomputed for native candidates. Materialization reduced the three measured debug queries to 46–57 ms with the same exact results. These are single synthetic trials with uncontrolled caches/activity, not release latency percentiles, natural relevance, energy or competitor results.

The earlier 35-query authored fixture retains every aggregate quality component for Apple and local Qwen across keyword/hybrid/semantic modes. This does not solve its known absent-evidence candidate/abstention weakness or establish broad generalization. [Scoped evidence](../benchmarks/search-expressions-v1.json) records tests, hashes and retained failures. Rendered light/dark UI checks are separate from native input/help/keyboard acceptance, which remained pending when the Mac locked.
