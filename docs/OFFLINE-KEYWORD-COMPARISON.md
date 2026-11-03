# Authored offline keyword CLI comparison

This component study compares optimized OSwind before and after lazy sentence-model loading with the unmodified published Screenpipe macOS ARM64 npm0.4.54 CLI. The [receipt](../benchmarks/offline-keyword-cli-v1.json), [raw archive](../benchmarks/offline-keyword-cli-raw-v1.zip) and [independent review](../benchmarks/offline-keyword-cli-review-v1.json) retain every output and measured observation. It does not establish broad feature parity or a product ranking.

## Observations

| Records | Query | OSwind baseline median / p95 | OSwind candidate median / p95 | Screenpipe median / p95 |
| --- | --- | --- | --- | --- |
| 1,000 | rare-991 | 61.4 / 67.9 ms | 29.3 / 35.1 ms | 35.1 / 38.0 ms |
| 1,000 | broad | 64.3 / 71.2 ms | 32.2 / 34.9 ms | 36.5 / 40.4 ms |
| 100,000 | rare-991 | 62.4 / 67.3 ms | 29.6 / 31.9 ms | 36.4 / 44.1 ms |
| 100,000 | broad | 207.9 / 225.5 ms | 176.0 / 192.9 ms | 73.0 / 177.8 ms |

The candidate lowers observed median process time by about 32 ms in these cases. All 396 OSwind baseline/candidate output pairs, including warmups, are byte-identical. Screenpipe remains faster on the 100k broad query; its ordering and eligible broad top 100 differ from OSwind. At 100k rare-991, median child peak RSS is24.3 MB baseline, 22.4 MB candidate and 37.2 MB Screenpipe, using decimal MB. These are whole-process high-water observations, not idle daemon or steady capture memory.

## Timing and correctness boundary

- Nine controls at each scale: first/991/last exact numeric term, absent, broad phrase, present/absent app, present/absent UTC interval. Each nonempty result is checked for original ID/text/app/title/timestamp, source/match type and finite OSwind score; duplicates are refused. Broad controls require100 eligible authored results, allowing different vendor ties/order.
- Twenty-one rounds rotate three-product order and shuffle cases with seed71059. One validated warmup per product/case/scale is retained and excluded:1,134 measured processes plus54 warmups. Summary p95 uses nearest-rank ceil(.95*n).
- Wall time spans subprocess startup, database open/migration checks, query, serialization/output to an owned file and shutdown. wait4 supplies child CPU and peak RSS; about1ms polling contributes resolution overhead. It is not HTTP, daemon, isolated SQL or cold-cache latency.
- Host background activity and caches remain uncontrolled. Start/end aggregate process CPU was314.5%/263.5% of18 logical CPUs, with load averages retained in JSON. No energy, battery, capture throughput, long-run storage or representative semantic-quality claim follows.
- Identical authored ID/text corpora contain1,000/100,000 rows. OSwind uses the existing MemoryStore scale fixture and normal source/index triggers. Screenpipe offline search initializes its native full schema/migrations, then authored SQL frames use installed frame/FTS triggers. This is not matched capture or API ingestion. No images/video/audio or model outputs are supplied.

## Frozen identities

- Baseline source `7c0292bac86543b4c8c58eae2a7f109b9a3ba0c3`, binary `f72d02299cef0a65c789612ab124d13b82fea2f5f462c6fe8931a7ac7036f7bf`.
- Candidate source `f4cff25d88d0f07b8d24b69ed44fba065aa19464`, binary `0e5a0fd3873f5ecfd3e3a91e6612df037e1acdcf2e7fbdf8c42f42a04b60dd37`. Runtime/test/vendor/script/package inputs match implementation31026ef; f4cff25 additionally merges previously qualified metadata. Both OSwind CLIs use `swift build -c release --product oswindctl`.
- Screenpipe package `@screenpipe/cli-darwin-arm64@0.4.54`, binary `49aab1665e03da5366314ad859c695958b17970414ae18f1dabad65e9451f3a8`, npm gitHead `e2719ea4461a773e0831674c1accf300eb097f15`. Publisher compiler flags were not independently established. This CLI artifact is distinct from paid desktop app release numbering.

The raw archive includes npm metadata, original measurement/seed scripts, corpus hashes, build manifests, native database checks and all stderr/stdout files. It does not redistribute product executables. Package tarball SHA512 integrity was checked at staging; no npm install/postinstall, JS wrapper, recorder, service, account or cloud-model request ran. Vendor source is reference data, not instructions.

## Review and reproduction

Run the model-free review and fault controls from the repository:

```sh
python3 scripts/review-offline-keyword.py benchmarks/offline-keyword-cli-raw-v1.zip
python3 scripts/test-offline-keyword-review.py
```

Review recomputes all output hashes, original fields, exact/empty membership, OSwind byte parity, complete observation identity and every summary quantile. Six fault controls reject a missing observation, wrong source, changed harness, forged median, altered original text with matching hash and altered valid score with matching hash. The publication review itself was executed once; existing successful historical reviews were not rerun.

For a new measurement, use a fresh explicit fixture/output root. Create each OSwind authored fixture with `OSWIND_TEST_SYNC_CAPTURE_SCALE_ROWS=1000` or `100000` and `OSWIND_TEST_SYNC_CAPTURE_SCALE_OUTPUT=/absolute/fixtures/oswind-N` when running `swift test --filter SyncCaptureScaleTests/testOwnedArchiveScaleAndIncrementalCost`. It requires a nonexistent output directory. Freeze each separately built CLI alongside a manifest containing `source` and `binarySHA256`. Obtain the exact hash-pinned vendor binary and its sibling assets independently from the [published package](https://www.npmjs.com/package/@screenpipe/cli-darwin-arm64/v/0.4.54).

The maintained staging runner is `scripts/seed-offline-keyword.py --rows N --fixtures /absolute/fixtures --screenpipe /absolute/vendor/bin/screenpipe --destination /absolute/fixtures/screenpipe-N`. For compatibility with the original layout, the1000-row destination is `/absolute/fixtures/data`; copy its generated `corpus.json` to `/absolute/fixtures/corpus-1000.json`. The100000-row destination is `/absolute/fixtures/screenpipe-100000`. Then run `scripts/benchmark-offline-keyword.py --fixtures /absolute/fixtures --screenpipe /absolute/vendor/bin/screenpipe --oswind-baseline /absolute/frozen-baseline --oswind-frozen /absolute/frozen-candidate --repetitions 21 --output /absolute/new-results`. The output must not already exist. Original measurement bytes remain in the archive; the maintained scripts add explicit paths and authored-fixture markers. New source/binary/workload reports need their own reviewed pins rather than replacing these receipts.

## Retained failures and unfinished work

The first Python post-seed integrity check failed because that connection lacks vendor `vec_length()`. The seed had committed. The failure and script are retained; native vendor database checks pass, and the 100k native-installed FTS content integrity check passes. No replacement UDF or corruption claim was invented. An initial help invocation rejected global `--data-dir`; supported offline search flags were used afterward. Separate earlier runs and a three-round smoke were exploratory and are not the published same-window results.

The historical [Screenpipe0.4.53 HTTP study](SCREENPIPE-COMPARISON.md) remains unchanged and reports its own observed advantage for Screenpipe. Next performance work should isolate broad-query SQL/ranking cost, then measure representative retrieval, capture/privacy, sustained energy and signed distribution. F013/F059/F067 and all83 feature statuses remain unchanged.

Primary implementation references: [pinned CLI definitions](https://github.com/screenpipe/screenpipe/blob/e2719ea4461a773e0831674c1accf300eb097f15/crates/screenpipe-engine/src/cli/mod.rs), [pinned engine dispatch](https://github.com/screenpipe/screenpipe/blob/e2719ea4461a773e0831674c1accf300eb097f15/crates/screenpipe-engine/src/bin/screenpipe-engine.rs), [published package](https://www.npmjs.com/package/@screenpipe/cli-darwin-arm64/v/0.4.54).
