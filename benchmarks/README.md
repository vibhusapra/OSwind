# Benchmark protocol and results

No overall ranking against other products has been established. Competitor features are documented in the research report; competitor runtime performance has not been measured.

## Reproduce retrieval

```bash
swift build -c release
.build/release/oswindctl benchmark --count 1000 --output benchmarks/oswind-1000.json
.build/release/oswindctl benchmark --count 10000 --output benchmarks/oswind-10000.json
```

The benchmark creates and removes an isolated temporary store. Twelve topic templates are repeated to fill the requested record count; 12 queries run three times across keyword, semantic and hybrid retrieval. It reports ingest throughput, disk bytes, hit rate@5, MRR@5, and p50/p95 including query embedding. Relevant items are any record with the expected topic label. This is a fast regression/scaling fixture, not a representative user study. Repeated topics can crowd out other sources and overstate recall. Semantic search scans every filtered vector.

Initial debug result on Apple M5 Max/macOS26: 1,000 rows ingested at ~116 records/s; ~7.75 MB database directory; hybrid p95 ~7.1 ms, hit@5 1.0, MRR .917. Keyword beat hybrid on this fixture. Semantic-only hit@5 .583 is a known quality limitation. Results must be regenerated after retrieval changes; retain build configuration with reported results.

## Full comparison gates

1. Pin each product version, OS/hardware, display scale, inference model and power profile.
2. Use identical public/synthetic screen traces, audio clips, activity/idle periods and privacy fixtures. Keep competitors' default and tuned runs distinct.
3. Measure index lag, transition capture recall, OCR CER/WER, audio WER/RTF, query p50/p95/cold start, Recall@k/MRR/no-evidence abstention, source correctness, CPU/RSS, bytes/hour and power with a physical meter or supported profiling setup.
4. Run sustained active, meeting, idle and low-power sessions and a 24-hour fault/soak test. Test sleep, restart, permission revocation, full disk, model failure, import interruption and audio hardware changes.
5. Store raw logs and workload manifests, explain unmeasured axes, and avoid composite rankings until weights and gates are explicit.

`idle-debug.json` samples a paused debug process while the Mac is locked; it is not an active capture or battery benchmark. `ps` CPU values are lifetime averages, not interval energy measurements.
