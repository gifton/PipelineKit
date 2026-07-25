# CI Configuration Notes

## Platform Configuration (Updated December 2025)

All CI workflows have been updated to use:
- **Runner**: `macos-26` (macOS 26 Tahoe)
- **Xcode**: `latest-stable` via `maxim-lobanov/setup-xcode@v1`
- **Swift**: Uses Xcode-bundled Swift toolchain (no separate `swift-actions/setup-swift`)
- **iOS Simulator**: iPhone 17 with iOS 26.0

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

### 4. NextGuard Warning Configuration
- **Default**: Timeout warnings are automatically suppressed
- **Optional**: Set `PIPELINEKIT_DISABLE_NEXTGUARD_WARNINGS=1` to disable all warnings
- **Current**: Using defaults (warnings enabled but timeout false positives suppressed)

## Environment Variables

| Variable | Purpose | Required | Default |
|----------|---------|----------|---------|
| `DEVELOPER_DIR` | Xcode path | Yes | `/Applications/Xcode.app/Contents/Developer` |
| `CI` | CI mode flag | Yes | `true` |
| `MINIMUM_COVERAGE` | Coverage threshold | No | 70 |

## Workflows Overview

| Workflow | Trigger | Runner | Purpose |
|----------|---------|--------|---------|
| `ci.yml` | Push/PR | macos-26 | Main CI pipeline |
| `ci-multiplatform.yml` | PR/Manual | macos-26 | iOS/watchOS simulator tests |
| `weekly.yml` | Monday 2AM UTC | macos-26 | Weekly extended test suite |
| `weekly-full-ci.yml` | Sunday 3AM UTC | macos-26 | Comprehensive testing |
| `specialty-tests.yml` | Label/Manual | macos-26 | Memory/perf/stress tests |
| `release.yml` | Tag push | macos-26 | Release automation |

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
- **Impact**: per-target test phase ~45s → ~15s expected.

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

Current CI timings (sequential):
- Build: ~30s
- Tests: ~45s
- Coverage: ~10s
- Total: ~85s per configuration

## Linux Support

Linux builds use Docker container `swift:6.2`:
- Set as `continue-on-error: true` (secondary platform)
- Requires additional system dependencies
- **Build-only**: both Linux jobs run `swift build` — no tests execute on Linux
- Uses Swift 6.2 only (no legacy version testing)

## Troubleshooting

### Tests Failing in CI but Passing Locally
1. Check for timing-sensitive tests
2. Verify environment variables match
3. Consider CI hardware differences

### Coverage Upload Failures
1. Verify `CODECOV_TOKEN` secret is set
2. Check that test binary exists at expected path
3. Ensure profdata was generated with `--enable-code-coverage`

### Xcode Setup Issues
1. Verify `macos-26` runner is available
2. Check that `latest-stable` Xcode version exists
3. Review `maxim-lobanov/setup-xcode` action logs

## Future Improvements

1. **Fix parallel test execution** - Investigate and resolve hanging issue
2. **Add benchmark regression detection** - Compare results against baseline
3. **Caching improvements** - Cache Xcode DerivedData more effectively
4. **Add performance gates** - Fail if performance degrades significantly
