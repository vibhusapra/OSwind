# Optional system-power observation

`scripts/power_telemetry.py` records finite system-counter observations using an
explicitly selected optional macmon executable. It is a development tool; the
OSwind application does not depend on macmon or acquire new private-API code.
No root, service, TUI, process/file inspection or device/power setting is used.
The long-run battery/CPU-budget feature remains TODO.

The [pinned tool receipt](../benchmarks/tools/macmon-v0.10.0.json) specifies the
official v0.10.0 archive and executable digests, source revision and original MIT
license. The archive digest matches GitHub release metadata. This is a prebuilt
release; its binary/source equivalence was not independently proved. The
[pinned pipe branch](https://github.com/vladkens/macmon/blob/5df67a54e082e0b30a0aa2b48b7c7f78a36f1795/src/app/main.rs)
constructs a sampler, serializes system metrics and exits after its sample count.
The [sampler implementation](https://github.com/vladkens/macmon/blob/5df67a54e082e0b30a0aa2b48b7c7f78a36f1795/src/metrics.rs)
uses IOReport/SMC data. These are system estimates with platform-dependent
availability, not calibrated wall-plug measurements or process-attributed watts.

## Run

Obtain the optional official release separately and verify both hashes from the
receipt before execution. The tool is not automatically downloaded or installed.
Use an existing private output directory and a new output filename:

```sh
python3 scripts/power_telemetry.py \
  --sampler /absolute/private-tool/macmon --samples 20 --interval 1000 \
  --output /absolute/private-output/new-observation.json
python3 scripts/test-power-telemetry.py
```

The CLI requires macOS and the exact pinned executable. The library function's
explicit expected-hash parameter supports generated-data protocol tests or a
separately verified local build. Do not treat an arbitrary executable as trusted
merely because it accepts these flags. Source-built tools require their own
frozen provenance before comparisons.

The observer whitelists numeric power/activity fields and timestamps. Unknown
future fields are dropped before persistence. It refuses nonfinite/negative
values, missing fields, Boolean/string numbers, naive timestamps, duplicate or
reversed rows, oversized/partial streams and incomplete counts. Limits are
1–600 samples, 100–10,000 ms intervals, 256 KiB per line and 16 MiB total output.
It enforces a deadline, suppresses child stderr, and terminates/reaps only its
owned child on failure, including sampling from another thread. Output is new
and mode 0600. No HTTP listener, user library or provider key is involved.

Zero is retained as zero; it does not prove a channel is supported or fresh.
Gap/clock-divergence receipts are observations, not automatic acceptance of a
stable trace. `MACMON_FORCE_CLPC` is removed only from the child environment to
select the pinned tool's default automatic behavior.

## Observed on this M5 Max / macOS26.6.2

[Qualification](../benchmarks/power-telemetry-v1.json) passes eight offline
admission/transport/cleanup cases without hardware access or downloads. A
20-sample finite run completes in 20.97 s, uses 0.345 child CPU seconds and peaks
at 19,120,128 bytes RSS. Its maximum sample gap is 1.016 s; arrival clock divergence
is under 0.00001 s. Startup/discovery is included. These numbers describe that
observer invocation, not steady-state overhead or OSwind resource use.

A separate frozen responsiveness protocol records 40 system samples around
10 seconds before, two owned CPU hash workers for 15 seconds, then 10 seconds
after. Samples within two seconds of phase edges are omitted from phase medians.
The workers consume 29.03 CPU seconds total; no GPU workload is introduced. Each Python3.15 worker repeatedly computes SHA256 over `b"OSwind owned CPU calibration " * 4096` until a15-second monotonic deadline. The frozen original protocol and driver hash remain in the report; the original phase driver is a local experimental harness, while the reusable finite observer above is shipped.

| Reported system median | Before | Owned CPU phase | After |
| --- | ---: | ---: | ---: |
| CPU power estimate |2.964 W |3.400 W |2.674 W |
| GPU power estimate |10.376 W |10.702 W |11.137 W |
| System power estimate |50.807 W |51.697 W |51.127 W |
| CPU active ratio |0.143 |0.322 |0.142 |

All 40 rows are finite/nonnegative; gaps are 1.004–1.020 s. The CPU estimate rises
during the owned work, while the GPU also drifts. Background activity remains
uncontrolled, so this establishes availability and temporal responsiveness on
this host. No OSwind energy savings, app attribution, external calibration,
background-capture efficiency or battery-life claim follows from it.

An energy comparison needs its own frozen workloads, idle controls, sampling
windows, missing/stale-data rules and system-versus-process attribution. The
earlier visual-loader comparison measured time/CPU/RSS only; telemetry is not
retroactively added to those trials. Representative Light/Balanced/Detailed
recording budgets still require an unlocked owned/public fixture and native
device acceptance. No new battery-budget status is claimed here.
