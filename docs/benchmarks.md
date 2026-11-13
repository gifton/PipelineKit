# Performance measurements

`Scripts/run-performance-tests.sh` builds a standalone Swift 6 executable in
Release mode and writes checked JSON measurements. It requires a host running macOS 26 or
later and the package's supported Swift toolchain. The executable uses the public
PipelineKit products without changing the production dependency graph.

The four workloads run serially, with all async work awaited:

| Workload | One operation | Consumed result per batch of N |
| --- | --- | --- |
| dispatch | Execute an integer command through a `StandardPipeline`, reusing a context, with no middleware | Sum of returned integers, N(N+1)/2 |
| context | Write and read one integer metadata value on a reused context | Sum of observed integers, N(N+1)/2 |
| admission | Admit a request to a fresh global token bucket of capacity N, zero refill | N successful admissions |
| telemetry | Record a counter snapshot into `MetricsStorage`, retaining N observations in one series | N observations whose values sum to N |

Each batch creates fresh state before timing. Dispatch includes the first
execution's context initialization. Context timing includes read verification
and summation; dispatch and admission timing include result accumulation.
Telemetry reads and checks retained observations after its timed recording loop.
Setup, JSON encoding and destruction of batch state occur outside timing. Every
warm-up batch also checks its results.

The workloads run inside one detached task, so the calling code is on Swift's
cooperative thread pool rather than the main thread. The harness detaches nothing else.
Code that awaits a pipeline from the main actor is therefore not what these
workloads measure. See [Caller context](#caller-context) for that case.

## Published results

Measured on PipelineKit 0.6.0 (`74e7fc6`, tag `v0.6.0`) with the harness at `945dad2`.

| | |
| --- | --- |
| Machine | Apple M3 Max (Mac15,9), 16 cores, 48 GiB |
| OS | macOS 27.0.1 (26A434) |
| Toolchain | Apple Swift version 6.4.2, Xcode 27.2; Release configuration |
| Power | AC, power mode 2 (high power) |
| Parameters | 1,000 operations per batch; 200 timed batches per launch after 20 discarded warm-up batches; 5 launches |

```text
Source: 74e7fc64ddc667001d32b0417b7fde89df3a37b2 (tree 4429256b3b2c0b9b3eeb9d757c27febe4da7c9f235982431a4908b423991db71), clean
Toolchain: Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
Host: Mac15,9, arm64, 16 CPUs, 48 GiB, macOS-27.0.1-arm64-arm-64bit-Mach-O
Parameters: 1000 operations/batch, 200 timed batches x 5 runs, 20 warm-up batches/run
Harness: 10369909078ecf432d460a08a10dd68eff766b0fce37fa2cc06a5f35ff3c64fe
```

| Workload | Median ns/op | p95 ns/op | Min ns/op | Max ns/op | Run medians ns/op |
| --- | ---: | ---: | ---: | ---: | ---: |
| dispatch | 1001.8 | 1057.4 | 933.1 | 1103.3 | 982.3-1026.4 |
| context | 212.2 | 228.8 | 194.4 | 250.8 | 208.3-216.7 |
| admission | 492.3 | 524.1 | 456.0 | 586.5 | 486.4-512.5 |
| telemetry | 7865.9 | 8346.5 | 7490.1 | 9037.0 | 7627.6-8307.4 |

Every figure is a whole-batch duration divided by the operations in the batch. "p95" is the
nearest-rank 95th percentile of those batch means across all five launches. None of these is
the latency distribution of individual calls; the harness does not time single calls. "Run
medians" is the lowest and highest per-launch median, which shows how much the result moves
between launches. These are one machine's numbers. The machine was not idle: its load average was
between 4 and 9 while the records were collected, mostly from system indexing services.

### Batch size

The same measurement with 100 and with 10,000 operations per batch, one launch each.

100 operations per batch:

| Workload | Median ns/op | p95 ns/op | Min ns/op | Max ns/op | Run medians ns/op |
| --- | ---: | ---: | ---: | ---: | ---: |
| dispatch | 1054.0 | 1089.6 | 1000.4 | 1215.8 | 1054.0-1054.0 |
| context | 226.7 | 227.9 | 220.4 | 276.2 | 226.7-226.7 |
| admission | 507.7 | 637.5 | 484.6 | 700.0 | 507.7-507.7 |
| telemetry | 994.6 | 1069.6 | 989.2 | 1229.6 | 994.6-994.6 |

10,000 operations per batch:

| Workload | Median ns/op | p95 ns/op | Min ns/op | Max ns/op | Run medians ns/op |
| --- | ---: | ---: | ---: | ---: | ---: |
| dispatch | 988.9 | 1011.2 | 974.0 | 1022.3 | 988.9-988.9 |
| context | 208.6 | 217.2 | 197.7 | 220.6 | 208.6-208.6 |
| admission | 495.3 | 526.2 | 470.7 | 544.4 | 495.3-495.3 |
| telemetry | 78029.0 | 79280.0 | 76730.8 | 81590.9 | 78029.0-78029.0 |

Median ns per operation at 100, 1,000 and 10,000 operations per batch: dispatch 1054.0,
1001.8 and 988.9; context 226.7, 212.2 and 208.6; admission 507.7, 492.3 and 495.3. For these
three workloads the 100- and 10,000-operation medians are within 7% of the 1,000-operation one.

Telemetry is 994.6, 7865.9 and 78029.0. Each telemetry batch starts with an empty series and
retains every observation, and `MetricsStorage.record` copies that series' retained history on
each call, so the cost of a call grows with the history length. Read the telemetry row as the
mean cost of one record while a series grows from empty to N retained observations, not as a
constant.

### Caller context

The harness calls from a task on the cooperative pool. Code that awaits a pipeline from the
main actor pays a hop to the pipeline's actor and back to the main thread on every call. The
same workloads driven from the main thread (harness as of `61732e2`, one launch, same
parameters) measured:

| Workload | Median ns/op | p95 ns/op | Min ns/op | Max ns/op | Run medians ns/op |
| --- | ---: | ---: | ---: | ---: | ---: |
| dispatch | 7548.8 | 9012.1 | 6063.1 | 10493.6 | 7548.8-7548.8 |
| context | 213.5 | 224.8 | 208.8 | 241.5 | 213.5-213.5 |
| admission | 8342.9 | 8478.6 | 7450.5 | 8844.5 | 8342.9-8342.9 |
| telemetry | 15592.4 | 17988.0 | 14908.5 | 18438.8 | 15592.4-15592.4 |

The context workload awaits nothing, and it is the one row that does not move.

### Reproducing these

The raw records are in [`benchmark-records/0.6.0/`](benchmark-records/0.6.0/). Each carries
the source revision, a digest of the sources, the harness digest, the toolchain version and
the hardware model, core count, memory and OS version. The `text` block above the first table
is the identity header `summarize.py` prints for the five 1,000-operation records.

Three fields were redacted before the records were committed, with
`Scripts/benchmarks/redact.py`: `hardware.host` (the machine's host name) and
`build.swift_executable` (the resolved path of `swift`) hold the placeholder `"<redacted>"`,
and any value set in `build.environment` would hold it too. All nine of those variables were
unset during collection, so they remain `null`. Nothing else was altered; the samples,
checksums, revisions and digests are as the runner wrote them. Because of the placeholders,
`compare.py` treats a published record and a fresh local one as different builds and hosts and
refuses to compare them.

To regenerate the tables from the records:

```bash
python3 Scripts/benchmarks/summarize.py docs/benchmark-records/0.6.0/pool-n1000-run{1,2,3,4,5}.json
python3 Scripts/benchmarks/summarize.py docs/benchmark-records/0.6.0/pool-n100.json
python3 Scripts/benchmarks/summarize.py docs/benchmark-records/0.6.0/pool-n10000.json
python3 Scripts/benchmarks/summarize.py docs/benchmark-records/0.6.0/main-thread-n1000.json
```

To measure the same revision on your own machine:

```bash
git clone --branch v0.6.0 --depth 1 https://github.com/gifton/PipelineKit.git /tmp/PipelineKit-0.6.0
for i in 1 2 3 4 5; do
  bash Scripts/run-performance-tests.sh --source-root /tmp/PipelineKit-0.6.0 \
    --scratch-path .build/benchmarks/published --samples 200 --operations 1000 --warmup 20 \
    --output .build/benchmarks/published-run$i.json
done
python3 Scripts/benchmarks/summarize.py .build/benchmarks/published-run{1,2,3,4,5}.json
```

`summarize.py` refuses records that differ in source, build, hardware or parameters, and
records measured on a checkout with uncommitted changes.

## Collect and compare

Create an explicit baseline, then collect the candidate using the same settings:

```bash
bash Scripts/run-performance-tests.sh \
  --samples 15 --operations 1000 --warmup 3 \
  --output .build/benchmarks/baseline-run.json \
  --baseline .build/benchmarks/baseline.json --update-baseline

bash Scripts/run-performance-tests.sh \
  --samples 15 --operations 1000 --warmup 3 \
  --output .build/benchmarks/candidate.json \
  --baseline .build/benchmarks/baseline.json --compare
```

`--baseline` takes a JSON file path. `--update-baseline` replaces that file only
after a successful, validated run. `--compare` requires an existing valid
baseline; it cannot be combined with `--update-baseline`. Build, workload and
validation failures return nonzero. `--debug` and the old XCTest `--filter`
option now fail explicitly because they cannot select these matched Release
workloads. `--help` lists the supported arguments.

Use `--source-root /path/to/checkout` to build a different revision with the
current harness. Use a separate `--scratch-path` for each source checkout and
`--jobs` to control build parallelism. The source checkout must retain its Git
identity and tracked `Package.resolved`. The runner seeds the standalone
package's lockfile from it and checks every effective resolved dependency
revision against that file before executing the workloads.

For a stored pair, no rebuild is necessary:

```bash
python3 Scripts/benchmarks/compare.py baseline.json candidate.json \
  --max-regression 1.10
```

Ratios are candidate divided by baseline; smaller is faster. Comparison is
**advisory by default**: exceeding the ratio limit is reported numerically while
the command succeeds. Add `--enforce` to fail if either a workload's median or
its p95 batch duration ratio exceeds `--max-regression` (a finite ratio at least
1). Invalid, incomplete or incompatible records always fail, even in advisory
mode. Correctness qualification remains separate from this hardware-sensitive
policy.

## Units, identity and limits

Schema version 1 records the source Git revision, a SHA-256 digest of
`Package.swift`, `Package.resolved` and all source files, and the dirty checkout
state. It records the harness digest, Release configuration, Swift version and
executable, selected toolchain/build environment variables, dependency-lockfile
digest, host/model/architecture/OS, CPU count and physical memory in bytes.
Physical memory is hardware capacity, not process memory usage.

Parameters include operations per batch, measured batch count, and warm-up
batch count. Every workload stores its raw **nanoseconds per batch** samples,
checked operation counts, observed checksums, and the expected checksum. The
comparator validates positive finite samples and the workload-specific checksum
formula, and requires matching workload, hardware, toolchain, build and parameter
identity. Source revisions/digests may differ because those are what a candidate
comparison evaluates.

The report's median `ns/op batch mean` divides the median batch duration by N.
It is a throughput-oriented batch average. The p95 uses the nearest-rank element
`ceil(0.95 * sampleCount)` of sorted **whole batch** durations; with 15 samples
it is the maximum batch duration. These measurements do not provide individual
request p95/p99 latency. Increase sample counts for a better view of batch
variability; the tool does not estimate statistical significance.

Allocation instrumentation is explicitly **unavailable** in this harness.
Schema 1 records that fact and its reason; it does not substitute RSS or host
memory for allocation counts, and makes no allocation-regression claim. Attach
an allocation profiler separately when investigating memory behavior.

Measure an otherwise idle machine after builds have completed. Keep hardware,
power mode, temperature, toolchain, settings and workload fixed. The runner does
not control thermal throttling or background activity. Sequential comparisons
can still reflect system noise; repeat any material regression before attributing
it to source changes.

## CI and XCTest

The specialty workflow's `performance-baseline` job checks out baseline source
separately and uses the candidate's harness for both measurements. It collects
matching Release records, runs the numerical comparator with an advisory 1.10
ratio limit, and uploads both JSON files and the report, including partial
artifacts on failure. Missing data is fatal. Use explicit `--enforce` locally or
in a controlled runner policy to enforce the timing limit.

The existing `PipelineKitPerformanceTests` XCTest target remains available:

```bash
swift test -c release --filter PipelineKitPerformanceTests
bash Scripts/run-performance-tests-ci.sh
```

The CI XCTest wrapper preserves build and test failure codes. XCTest `measure`
calls stay in the performance target, as checked by
`PerformanceWorkflowTests.test_xctest_measurements_use_performance_target`.
XCTest output is separate from the JSON comparison path; this document does not
claim every XCTest case collects memory, CPU or storage metrics.

The comparator, CLI and specialty comparison behavior are covered by:

```bash
python3 -m unittest discover -s Scripts/ci/tests -p 'test_benchmark*.py'
```
