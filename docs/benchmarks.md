# Performance measurements

`Scripts/run-performance-tests.sh` builds a standalone Swift 6 executable in
Release mode and writes checked JSON measurements. It requires a macOS 26 host
and the package's supported Swift toolchain. The executable uses the public
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
warm-up batch also checks its results. No detached work is launched.

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
