# CI Configuration Notes

## Platform Configuration (Updated December 2025)

All CI workflows use the configuration below, except the two floor lanes in
`ci-multiplatform.yml` (`floor-macos`, `floor-ios`), which are described after it:
- **Runner**: `macos-26` (macOS 26 Tahoe)
- **Xcode**: `latest-stable` via `maxim-lobanov/setup-xcode@v1`
- **Swift**: Uses Xcode-bundled Swift toolchain (no separate `swift-actions/setup-swift`)
- **iOS Simulator**: an iOS 26.x iPhone simulator chosen at run time (`Find iOS Simulator` step in
  `ci-multiplatform.yml`; falls back to a generic simulator destination if none is listed)

The floor lanes use:
- **Runner**: `macos-15`. The `macos-26` image has no macOS 15 host and no iOS 18 simulator
  runtime.
- **Xcode**: pinned to `26.3`. The image's default Xcode is 16.4, which cannot build a
  tools-version 6.2 package, so `latest-stable` is not relied on.
- **No SwiftPM cache**: both lanes build from clean, so a `.build` directory produced by
  another Xcode or host OS is never restored into them.
- **iOS Simulator**: `Scripts/ci/run-simulator-tests.py` picks the lowest installed iOS 18
  runtime and fails if there is none; it does not fall back.

### Key Changes from Previous Configuration

1. **Removed `swift-actions/setup-swift`** - Now using Xcode's bundled Swift
2. **Removed legacy Swift versions** - No more 5.9/5.10 compatibility tests
3. **Removed macOS-13/14 runners** - Consolidated to macOS-26
4. **Added `DEVELOPER_DIR` environment variable** - Points to Xcode app

## Important Configuration Decisions

### 1. Parallel Test Execution Re-enabled (July 2026)
- **History**: `--parallel` was removed from all test commands because suites hung
  (see Known Issues #1).
- **Root cause (found July 2026)**: lost-wakeup races in the semaphores — a token
  release racing a waiter's cancellation could resume the already-cancelled waiter
  *with* the token, stranding the permit forever and parking every later acquire.
  Fixed in `SimpleSemaphore` (#73) and `BackPressureSemaphore` (#74);
  `AsyncSemaphore` had the tokenless variant, a swallowed signal (#76). Parallel
  execution never *caused* the hangs — it only widened the race windows (the hang
  reproduced in sequential runs too, at ~1/15 per full run).
- **Evidence for re-enabling**: 50/50 clean local full-suite `--parallel` runs with
  a hang-detection harness on main + #74 + #76 (a surviving 1/15 hang rate would
  pass 50 runs with probability ~3%).
- **If a hang recurs**: do NOT trust the log's last-started test (xctest stdout is
  block-buffered through the swift-test pipe and trails reality by 1-3 suites).
  Reproduce locally or get on the runner, and `sample <pid> 5` the live
  PipelineKitPackageTests process(es) BEFORE killing them. Sequential fallback:
  remove `--parallel` from the two per-target loop lines (`ci.yml`,
  `ci-multiplatform.yml`).

### 2. Job Dependencies Removed
- **Issue**: `needs: build` caused unnecessary job queuing
- **Solution**: Removed dependencies between build and test jobs
- **Benefit**: Jobs run in parallel, reducing total CI time
- **Trade-off**: Slightly higher resource usage

### 3. Coverage Generation
- **Issue**: Version mismatch between Swift compiler and system llvm-cov
- **Solution**: Use llvm-cov from Xcode toolchain via `xcrun --find llvm-cov`
- **Reports**: Open a GitHub Actions run and download `coverage-ci-macos` from
  the main CI workflow or `coverage-macos` from the multiplatform workflow.
  Each artifact contains `coverage.lcov`; no external coverage account is required.

## Environment Variables

| Variable | Purpose | Required | Default |
|----------|---------|----------|---------|
| `DEVELOPER_DIR` | Xcode path | Yes | `/Applications/Xcode.app/Contents/Developer` |
| `CI` | CI mode flag | Yes | `true` |
| `MINIMUM_COVERAGE` | Coverage threshold (reported, not enforced) | No | 70 |
| `ENFORCE_SWIFTLINT` | `'true'` makes SwiftLint violations fail the `swiftlint` job | No | `false` |
| `ENFORCE_COVERAGE` | `'true'` makes coverage below `MINIMUM_COVERAGE` fail the `test` job | No | `false` |
| `ENFORCE_PERFORMANCE` | `'true'` makes a failing performance-test run fail the `performance` job | No | `false` |

`MINIMUM_COVERAGE` and the three `ENFORCE_*` flags are set in `ci.yml` only.

## Workflows Overview

| Workflow | Trigger | Runner | Purpose |
|----------|---------|--------|---------|
| `ci.yml` | Push to `main`, `develop`, `test-ci`, `release/**`; PRs targeting `main`, `develop`, `release/**`; manual | macos-26, ubuntu-latest | Main CI pipeline; `CI Status` fails unless every job except the two advisory Linux builds succeeded |
| `ci-multiplatform.yml` | Every PR; push to `release/**`; manual; called by `release.yml` | macos-26, macos-15, ubuntu-latest | macOS Debug and Release tests and validation, iOS simulator tests, Swift 6.2 floor build, watchOS/tvOS/visionOS simulator builds; advisory macOS 15 host tests and iOS 18 simulator tests; `Multiplatform Status` fails unless every job except those two advisory lanes succeeded |
| `weekly.yml` | Monday 2AM UTC; manual | macos-26, ubuntu-latest | Weekly extended test suite, sanitizer runs, performance tests and all-severity Trivy scan |
| `specialty-tests.yml` | PR `labeled`/`synchronize` events (each test job runs only when its `test:*` label is present); manual | macos-26, ubuntu-latest | Memory, performance-baseline, stress and all-severity security jobs |
| `release.yml` | Push of a `v*` tag | macos-26 | Release notes validation, qualification, documentation, GitHub release |

## Known Issues

### 1. Parallel Test Hanging (resolved July 2026)
- **Symptom**: `swift test --parallel` hung indefinitely (~1 in 15 full runs; the
  same hang also occurred, less often, in sequential runs — issue #71).
- **Root cause**: semaphore lost-wakeup races (#73 `SimpleSemaphore`,
  #74 `BackPressureSemaphore`, #76 `AsyncSemaphore` tokenless variant):
  cancellation and release both spawned unstructured tasks that raced for the
  actor, and the losing interleaving trapped a permit forever.
- **Resolution**: `--parallel` re-enabled in the per-target CI loops after 50/50
  clean local harness runs (see Configuration Decisions #1).
- **Impact (measured, July 2026)**: total per-target test phase 89s → 82s (~8%).
  The old "~45s → ~15s" estimate predated today's larger suite; the big targets
  (PipelineKitTests 36s → 29s, ResilienceTests 33s → 24s) are dominated by
  wall-clock timing tests, which parallelism cannot compress. The primary value
  of `--parallel` is removing the historical workaround and continuously
  stress-testing the concurrency primitives (parallel runs widen race windows,
  so a lost-wakeup regression surfaces sooner).

### 2. ParallelMiddlewareContextTests Crash (stale)
- **Symptom**: SIGBUS (signal 10) crash in `testContextForkingPerformance` (historical)
- **Status**: The test was never actually skipped — commit `35394fd` only removed the
  `PipelineKitPerformanceTests` *target* from the CI target arrays. The test runs in CI
  today (under `PipelineKitResilienceTests`) without incident. Left enabled; revisit only
  if the SIGBUS reappears.

### 3. Flaky test-job failures (June 2026, resolved)
- **Symptom**: Multiple targets reported "failed with exit code 1" while their logs showed
  all tests passing (observed on the v0.5.0 release PR #59).
- **Root cause**: two stacked bugs. (a) `TimeoutDiagnosticTests.testDirectTimeoutUtility`
  genuinely failed — it raced a 0.1s timeout against a 0.2s operation, and on a loaded
  runner the starved timeout continuation lost ("Unexpected success after 0.229s").
  (b) The per-target loop didn't reset `TARGET_EXIT_CODE` between iterations, so that one
  failure cascaded false failures onto the five following targets — which misattributed
  the flake to `PipelineKitSecurityTests`.
- **Fixes**: cascade fixed in `0675b20`; timing margins widened to seconds in
  `TimeoutDiagnosticTests` (plus poll-based key-rotation wait in `EncryptionTests`).
- **Lesson**: timing-race tests must let the losing branch lose by seconds, not
  milliseconds; and only the FIRST failing target in a pre-`0675b20` log is trustworthy.

## Performance Benchmarks

Current CI timings (July 2026, `--parallel` per-target loop):
- Build: ~30s
- Tests: ~82s (was ~89s sequential; dominated by the timing-test-heavy
  PipelineKitTests and PipelineKitResilienceTests targets)
- Coverage: ~10s

## Linux Support

Linux builds use Docker container `swift:6.2`:
- Set as `continue-on-error: true` (secondary platform)
- Requires additional system dependencies
- **Build-only in `ci.yml`**: both of its Linux jobs run `swift build`; neither runs tests
- **Tests in `weekly.yml`**: the `Linux Test` job is set up to run the eight test targets
  (performance excluded), also with `continue-on-error: true`. Its test step previously
  stopped on a shell error (bash arrays under `sh`) before compiling; it now runs under
  `bash` and fails at compilation: `AuditLoggerCapacityTests.swift` (`stdout` is not
  concurrency-safe) and two `PipelineKitPoolingTests` telemetry test files (sending a
  non-`Sendable` test case) do not compile on Linux, so no Linux test has executed
- Uses Swift 6.2 only (no legacy version testing)

## Troubleshooting

### Tests Failing in CI but Passing Locally
1. Check for timing-sensitive tests
2. Verify environment variables match
3. Consider CI hardware differences

### Coverage Upload Failures
1. Check the collection/export step logs. All eight correctness-suite profiles
   must be present before export.
2. Verify that export produced a nonempty `coverage.lcov`. Missing or malformed
   coverage fails validation before artifact upload.
3. Inspect the GitHub artifact-upload step; a missing report fails the job.

### Xcode Setup Issues
1. Verify the `macos-26` runner (and `macos-15` for the floor lanes) is available
2. Check that `latest-stable` Xcode version exists, and that Xcode 26.3 is still on the
   `macos-15` image
3. Review `maxim-lobanov/setup-xcode` action logs

## Future Improvements

1. **Caching improvements** - Cache Xcode DerivedData more effectively
2. **Add performance gates** - Fail if performance degrades significantly
