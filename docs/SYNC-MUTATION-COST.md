# Sync mutation cost

The indexed candidate passes all 22 [functional qualification stages](../benchmarks/sync-mutation-cost-qualification-v1.json) and the complete [three-round paired experiment](../benchmarks/sync-mutation-cost-v1.json), with [719 repository inputs pinned](../benchmarks/sync-mutation-cost-inputs-v1.json). All twelve workload processes and independent reviews pass; 66,000 current/original bindings, 120 retained prior packets and 66,000 causal child barriers are checked. Exactly four runtime inputs differ between profiles. F059 remains TODO; this component does not enable device synchronization or establish product ranking or power consumption.

## Measured tradeoff

All samples are published in the receipt. Three rounds use AB, BA, AB order with no replacement slots. Warm deletion medians improve from **1.563 to 1.210 seconds at 1k** (22.6% less) and **72.203 to 19.312 seconds at 10k** (73.3% less). Every 10k paired deletion sample improves by about73%; the baseline database uses an identity-table scan and the candidate uses the covering index.

The whole two-size deletion workload, including fixture preparation, improves from **227.824 to 183.202 seconds** median (19.6% less). Projection costs increase: 1k incoming median17.432→18.140 seconds (+4.1%); 10k177.450→180.863 seconds (+1.9%); whole projection workload346.812→360.273 seconds (+3.9%). Ten-run update medians are0.212→0.215 seconds at1k and0.203→0.220 at10k. Outgoing preparation medians also increase: at10k, projection135.621→145.716 seconds and fanout139.224→146.412 seconds. This is a deletion optimization with retained write/setup costs, rather than an overall sync-throughput improvement.

The first-round 10k pre-deletion database grows from48,615,424 to50,008,064 bytes (+1,392,640 bytes); `dbstat` attributes1,355,776 bytes to the new index. At1k the index occupies135,168 bytes. The receipt includes every profile/round database size, page count and index cost. Readonly inspection verifies file hashes, permits only empty WAL/journal files and does not change the databases. An initial analysis-script assertion wrongly rejected retained empty sidecars; that script error and correction are retained and did not rerun any benchmark.

All eleven corruption controls refuse actual copied indexed output; restored positive review passes and originals remain unchanged. During trial1, separate managed-worktree setup and the app's Git snapshot caused background CPU/IO; no Swift compiler or other tests ran during timing. Caches and background activity were uncontrolled throughout. These three samples establish this authored component observation, not an isolated hardware experiment, physical energy result, model/media/transport performance or competitor ranking.

## Changes under test

- Cache the fixed connection-local retirement schema definitions.
- Observe an admitted root immediately before the first new child announcement; avoid an observation write for a mutation with no child publication.
- Skip an observation UPDATE when the merged clock is unchanged. Subsequent local writes still observe the advanced peer cursor.
- Cover native deletion's identity lookup with `(table_name, local_key, object_digest)`. Validate the exact index definition, install it transactionally for existing catalogs on opening, and leave ordinary libraries un-enrolled. Identity lifetimes, original frames, journal state, schema31 and wire formats stay unchanged.

The first three index cases fail against the old implementation and pass with the fix. Two additional cases cover existing-library reopening and ordinary-library non-enrollment. The focused candidate run passes 100 cases with four explicit worker/opt-in skips, including child causality, rollback and real owned-process death. The full debug gate passes 1,619 cases/81 explicit skips with zero failures. Broad sanitizer and optimized gates each pass 619 cases/21 explicit skips, with all seven new mandatory cases executing in every build. The parent plus fourteen retained sanitizer worker logs have no race warnings.

All 22 functional stages pass over 721 unchanged inputs: 719 repository inputs and two private qualification drivers, including 459 Sources/Tests/Vendor files. A new strict signed/extracted 34-file app passes actual initialized/fresh old30 refusal, SDK, ordinary/indexed API/MCP, entity/correction/metadata, capture, original erasure, single deletion/wipe, recaps/routines and interrupted backups. All extracted files match; the installed 15-file app and five prior staged trees stay unchanged. Staged CLI SHA-256 is `9513c9371beb29388b87ba13976b2659fb044b9b12beb18938330abb005c6c9e`; ZIP SHA-256 is `5cea671bedba7e0776cf126c67bd532b5d7afb7771060de9be0639f0346e5bc4`. This is functional component evidence; accepted performance and complete service delivery remain pending.

## Retained partial experiment

The initial candidate changed only redundant schema construction and clock writes. Separately pinned optimized bundles completed the first baseline/candidate projection and deletion pair, with independent all-row reviews, at 1k and 10k records. Timings were close to baseline. Readonly inspection of the actual closed 10k pre-deletion database then found `SCAN personal_sync_identities` for the native deletion trigger's per-child lookup, over 10,001 identities. This identifies a scaling hypothesis; the plan alone does not attribute elapsed time.

The original three-round experiment was deliberately stopped during round two. Its owned worker exited by SIGTERM; the driver recorded the interrupted stage and released its temporary idle-sleep assertion. All partial measurements and the stop reason remain retained. No successful-only median, throughput improvement or completed paired result is accepted from that experiment.

An independent fan-out reader initially expected a nested clock field instead of the actual direct-map encoding. Its failure and corrected re-review of the same closed data are retained. Earlier control-driver errors and a new test's compilation error are also retained. The repository reader now passes eleven refusal controls and a restored positive copy; a changed native source is detected with its original protection triggers restored. Original SQLite files remain unchanged by those checks.

## Reproduction tools

Use separate baseline and candidate checkouts with **identical benchmark tests and tools**. The baseline's four runtime files must match `32982f1419723045d7680b1d3e415c2106d8ab2b`; the candidate carries the changes above. The builder never switches branches or replaces source files. Both dependency manifests must match. Each profile records its complete source manifest and frozen source copies, toolchain/build log, payload tree and executable hashes.

Create a fresh absolute output directory with mode `0700` and an `owned-fixture` file containing exactly `OSwind authored sync mutation profiles v1`, without a trailing newline. Do not use a live library or existing result directory.

From the respective checkout, stage each profile into that same output directory:

```sh
python3 scripts/stage-sync-mutation-profile.py /absolute/fresh/output baseline
python3 scripts/stage-sync-mutation-profile.py /absolute/fresh/output candidate
```

The baseline builder refuses modified production Sources/Vendor files. It compiles the identical test suite but executes a shared functional gate, rather than candidate-only regressions that intentionally fail on the baseline. Both copied bundles must link only system/XCTest libraries. The paired runner admits exactly the four declared runtime differences, matching dependencies, and pinned source and payload contents:

```sh
python3 scripts/benchmark-sync-mutation.py /absolute/fresh/output
```

Do not modify source, tests, dependencies, tools or pinned profiles, rebuild, or commit while that driver or a descendant lives, including interstage gaps. Observe and reap the existing process handle before changing inputs. An observation timeout is not a failed worker. The runner never rebuilds between measurements and uses fresh owned fixtures for every slot. Its temporary `caffeinate -i` assertion ends with the driver; it does not change a persistent device setting.

Independent readers and copied-data controls can also be invoked directly:

```sh
python3 scripts/review-sync-mutation-projection.py /absolute/output/runs/trial0-candidate/projection /absolute/output/candidate
python3 scripts/review-sync-mutation-fanout.py /absolute/output/runs/trial0-candidate/fanout /absolute/output/candidate
python3 scripts/test-sync-mutation-review.py /absolute/output/runs/trial0-candidate/fanout /absolute/output/candidate --output /absolute/fresh/control-output
```

The fan-out reader checks exact authored pre-delete native/wire identities and all child barriers, causal clocks, mapping retirement, cache revocation and accounting. It also checks the actual lookup plan against the pinned build's expected index. The projection reader verifies actual producer packets, current/native/original bindings, retained prior versions and exact receipts. Both require completed pinned executions, exact passing test counts, finite timings and closed SQLite databases; review must preserve each database hash.

## Acceptance protocol and limits

Three rounds alternate AB, BA, AB. Each profile/round runs projection and fan-out workloads at 1,000 and 10,000 records. Acceptance requires all twelve workload processes and independent reviews, all 24 per-size measurements, 66,000 current/original projection bindings, 120 retained prior versions and 66,000 retired child barriers. Publish every sample, paired differences and three-sample medians. Retain failures and interrupted attempts; do not fill a failed slot with a successful-only retry.

Phase timers exclude population, outgoing preparation, pre-delete backup and review; those costs and total process wall time are recorded separately. Projection uses actual typed producer packets and 128-record receiver transactions, ten updates, and seven warm history queries. Fan-out uses genuine receiver-only runs, one incoming recipe deletion, native cascading retirement and one causal journal barrier per child.

These are warm authored metadata components with uncontrolled caches and background activity. They exclude model/media/transport costs, cold-cache behavior, physical power and full sync service. The index's storage/install cost is part of setup, not a deletion-timer improvement claim. [Complete service gates](PERSONAL-SYNC.md), actual providers/two-Mac behavior, sustained capture/power and distribution still require their own evidence.
