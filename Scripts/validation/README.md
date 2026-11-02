# Stabilization validation tools

Run these commands from the repository root on macOS 26 or later with Swift 6.2 or
later and Python 3. Generated logs and manifests go under `.build/validation/` and
are ignored by Git. Choose a fresh run ID/prefix for each watchdog or precondition
invocation; those run artifacts are never overwritten. The documentation example
manifest and generated Swift source are regenerated in place.

## Public API and documentation examples

The [Consumer package](../../Tests/Integration/Consumer/Package.swift) uses ordinary
imports rather than `@testable`. It exercises public composition, security,
routing, cache identity, encryption, bulkhead, and metrics behavior, plus macOS
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
`cache-identity`, `encryption`, `bulkhead`, `metrics`, `statsd-startup`, `udp-close`,
and `udp-failure-close`. Use the watchdog for these lifecycle checks so a stalled
continuation cannot leave validation waiting indefinitely. These probes do not
replace the package's full Debug/Release test suites or platform CI.

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

## Command watchdog

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
