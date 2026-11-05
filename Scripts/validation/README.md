# Stabilization validation tools

Run these commands from the repository root on macOS 26 or later with Swift 6.2 or
later and Python 3. Generated logs and manifests go under `.build/validation/` and
are ignored by Git. Choose a fresh run ID/prefix for each watchdog or precondition
invocation; those run artifacts are never overwritten. The documentation example
manifest and generated Swift source are regenerated in place.

## Public API and documentation examples

The [Consumer package](../../Tests/Integration/Consumer/Package.swift) uses ordinary
imports rather than `@testable`. It exercises public composition, security,
routing, cache identity, encryption, bulkhead, error/cancellation policy, monitoring
and connection lifetime, resilience policy contracts, and metrics behavior, plus macOS
StatsD/UDP lifecycle cases. Its compiled documentation fixtures are generated
from the migration guide and examples changed since the stabilization baseline
pinned in the extractor. This is a batch-specific check, not a check of all docs.
The extractor requires Git history containing baseline commit
`a93a713d937e25f68855f22b0720f33c93329b09`; use a full checkout. Without that history,
the legacy extractor selects historical examples as well as this batch's changes.

```sh
python3 Scripts/validation/extract_stabilization_examples.py
swift build --package-path Tests/Integration/Consumer --configuration debug
swift build --package-path Tests/Integration/Consumer --configuration release
python3 Scripts/validation/run_check.py --id consumer-debug-001 --timeout 60 -- \
  swift run --package-path Tests/Integration/Consumer --configuration debug --skip-build Consumer composition-security
```

Run each mode in both configurations: `composition-security`, `routing`,
`cache-identity`, `encryption`, `bulkhead`, `error-contract`, `lifecycle`, `policy-contract`,
`metrics`, `statsd-startup`, `udp-close`,
and `udp-failure-close`. Use the watchdog for these lifecycle checks so a stalled
continuation cannot leave validation waiting indefinitely. These probes do not
replace the package's full Debug/Release test suites or platform CI.

The `policy-contract` mode checks public retry budgets and HTTP extraction, timeout
grace outcomes, rate priority/reset, and finite overload admission. CI builds and runs
it under the watchdog in both configurations. The policy tests include deterministic
clock and callback interleavings for boundaries that a public elapsed-time probe cannot force.

The `lifecycle` mode applies one owner-release assertion across health monitoring,
memory monitoring, hub-owned metrics, and the existing pool collector. It also acknowledges cancellation before
testing health-stop settlement and exercises public restart/disconnect APIs.
CI runs it under the watchdog in both configurations. Focused unit coverage adds
callback stop/restart, registration races, and conditional UIKit notification tests:

```sh
python3 Scripts/validation/run_check.py --id lifecycle-focused-001 --timeout 180 -- \
  swift test --filter 'HealthMonitorLifecycleTests|MemoryPressureLifecycleTests|MetricsConnectionLifecycleTests'
```

## Preconditions and removed plaintext API

Build the root Debug tests before running these isolated invalid-input checks.
The timeout and partition drivers require the intended precondition diagnostic,
not merely a failing child process. The encryption check requires a positive
decryption consumer to compile and the removed `originalCommand` access to fail
with exactly the expected missing-member diagnostic.

```sh
swift build --build-tests
python3 Scripts/validation/run_check.py --id timeout-driver-001 --timeout 180 -- \
  python3 Scripts/validation/check_bulkhead_timeouts.py --id timeout-cases-001 --wrapper all
python3 Scripts/validation/run_check.py --id partition-driver-001 --timeout 180 -- \
  python3 Scripts/validation/check_partition_configuration.py --id partition-cases-001
python3 Scripts/validation/run_check.py --id encryption-api-001 --timeout 60 -- \
  python3 Scripts/validation/check_encrypted_command_api.py
python3 Scripts/validation/run_check.py --id audit-negative-001 --timeout 60 -- \
  env S06_NEGATIVE_PROBE=1 SWIFT_BACKTRACE=enable=no swift test --skip-build \
    --filter AuditLoggerCapacityTests.testNegativeCapacityPreconditionProbe
```

The final command intentionally returns nonzero. Its `.build/validation/logs/audit-negative-001.log`
must contain both `S06_NEGATIVE_CAPACITY_REACHED` and
`Precondition failed: maxEvents must be nonnegative`; a different failure does not
validate the negative-capacity contract. The other three drivers must return zero.

## Concurrent pipeline admission timeout bounds

After building the root Debug tests, run the admission boundary driver under the
watchdog. It checks the semaphore constructor, concurrent pipeline constructor,
and explicit acquisition path with accepted boundary controls and rejected
nonfinite or oversized values. Rejection requires the probe's reached sentinel,
the intended precondition diagnostic, and absence of the accepted sentinel.
The driver writes individual logs and a JSON result to the selected directory.

```sh
python3 Scripts/validation/run_check.py --id admission-bounds-001 --timeout 180 -- \
  python3 Scripts/validation/check_admission_timeout_bounds.py \
    --logs /private/tmp/pipelinekit-admission-bounds-001
```

## Numeric boundaries and compression interoperability

Build the root tests in each configuration before running these host checks. The
numeric driver executes each input in an isolated test process with a 30-second
per-case timeout. On macOS it invokes the built XCTest bundle directly when
available. Accepted inputs must reach both probe sentinels and exit successfully;
rejected inputs must reach the probe, omit the accepted sentinel, and fail. Debug
also requires the precondition diagnostic; optimized Release builds may omit it.
Timeouts and unrelated startup failures do not count as successful rejection.
The numeric log directory must not already exist; it contains per-case logs and
`report.json`.

The matrix contains 434 cases, including all six `TimeoutTester` duration entry
routes and their derived arithmetic. Accepted large-duration test-helper probes
cancel their task before sleeping, after input validation. This avoids waiting
for the duration while still checking the conversion boundary.

The compression driver runs the built raw-DEFLATE output probe, then independently
decodes its four emitted samples with Python zlib. It requires exact original
bytes, end-of-stream, no trailing input, and rejection as zlib/gzip containers.
Portable XCTest fixtures separately cover canonical formats and every legacy
label, including output limits and truncated, trailing, concatenated, and empty
streams. The compression probe has a 60-second timeout; it retains partial output
and terminates its process group, escalating to KILL for surviving children.
Both drivers return nonzero on failure; neither builds Swift tests.

```sh
swift build --build-tests
swift build --configuration release --build-tests -Xswiftc -enable-testing
validation_run=.build/validation/numeric-compression-001
for configuration in debug release; do
  python3 Scripts/validation/check_numeric_boundaries.py \
    --configuration "$configuration" --logs "$validation_run/numeric-$configuration" || exit "$?"
  python3 Scripts/validation/check_compression_formats.py \
    --configuration "$configuration" --log "$validation_run/compression-$configuration.log" || exit "$?"
done
```

Choose a fresh `validation_run` for each invocation. The macOS job in
`ci-multiplatform.yml` runs both checks as fatal gates after the corresponding
Debug and Release tests. CI paths use
`$RUNNER_TEMP/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}` with separate configuration
names, so a rerun does not reuse the numeric driver's directory. The quick CI
Python suite executes these real workflow shell blocks with controlled driver
failures, checking that each failure remains fatal and both configurations and
log paths reach the drivers.
`test_numeric_probe_resolution.py` covers both SwiftPM bundle layouts and correct
configuration selection. `test_compression_watchdog.py` uses real controlled
processes to check timeout diagnostics and child termination, including refusal
of TERM. Both run in quick CI.

## Telemetry protocol output

The ordinary-import Consumer produces eight telemetry fixtures: repeated and
drained Prometheus scrapes, explicit reset, pool summaries, and sampled StatsD
counters with aggregation on/off, plus repeated pool StatsD snapshots. A pinned host-side `prometheus-client` parser
checks the real output; additional assertions enforce unique series, histogram
`+Inf`/count agreement, preserved labels, and cumulative totals. StatsD accounting
is applied independently to the emitted values and sample rates. This Python
package is a validation-only dependency.

```sh
python3 -m venv .build/validation/telemetry-venv
.build/validation/telemetry-venv/bin/python -m pip install -r Scripts/validation/telemetry-requirements.txt
python3 Scripts/validation/extract_stabilization_examples.py
for configuration in debug release; do
  swift build --package-path Tests/Integration/Consumer --configuration "$configuration" || exit "$?"
  .build/validation/telemetry-venv/bin/python Scripts/validation/check_telemetry_formats.py \
    --configuration "$configuration" --log ".build/validation/telemetry-${configuration}.log" || exit "$?"
done
.build/validation/telemetry-venv/bin/python Scripts/ci/tests/test_telemetry_oracle.py
```

The driver launches the prebuilt consumer with a 30-second deadline and retains
its output. Missing fixtures, an unacknowledged exit, protocol defects, or timeout
fail the check. CI runs both configurations as a fatal macOS gate. The numeric
driver also includes telemetry configuration boundaries in its isolated process
matrix. `TelemetryWorkflowTests` executes the real workflow shell with controlled
failures at each installation/build/validation stage.

## Command watchdog

For the cancellation and test-support changes, run the focused race checks under
Thread Sanitizer with a separate scratch directory and an external watchdog:

```sh
python3 Scripts/validation/run_check.py --id error-contract-tsan-001 --timeout 600 -- \
  swift test --scratch-path .build/error-tsan --sanitize=thread \
  --filter 'MockSnapshotContractTests|TestSynchronizerContractTests|PipelineCancellationBoundaryTests|SimpleSemaphoreErrorContractTests|SemaphoreCancellationErrorContractTests'
```

The quick CI Python suite also executes the actual stress workflow shell with
controlled failure, discovery, and empty-selection fixtures. The stress job uses
`Scripts/run-tests.sh --target PipelineKitResilience --verbose`; no fallback may
turn a failed or empty test selection into success.

`run_check.py` records a command's output, exit status, timeout, observed process
identities, and cleanup results. It returns nonzero for command failure, timeout,
or incomplete cleanup. `process_fixtures.py` checks ordinary exit, timeout,
descendant escape, parent exit, signal refusal, injected failures, and interruption.
`test_process_identity.py` checks PID reuse, inspection failure, duplicate IDs,
invalid deadlines, and fixture setup cleanup with an unrelated sentinel process.

```sh
python3 Scripts/validation/test_process_identity.py --prefix identity-001
python3 Scripts/validation/process_fixtures.py --prefix processes-001
swift build --build-tests --package-path Scripts/validation/HangFixture
python3 Scripts/validation/process_fixtures.py --prefix xctest-001 \
  --swift-package Scripts/validation/HangFixture --cases xctest_normal xctest
```

`HangFixture` is an isolated package containing an intentional hang. Run it only
through the fixture harness. The harness acknowledges process ownership before
allowing the hang and independently cleans up its test processes.

The watchdog supports macOS only. It observes descendants by polling and checks
PID/start-time identity before signaling. It cannot observe lineage that vanishes
between polls, and macOS provides no atomic identity-conditional signal operation.
It is intended for cooperative validation processes, not adversarial containment.
