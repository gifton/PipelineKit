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

### 1. Parallel Test Execution Disabled
- **Issue**: Tests hang when run with `--parallel` flag
- **Solution**: Removed `--parallel` from all test commands
- **TODO**: Investigate root cause - likely related to actor isolation or semaphore deadlocks

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
| `nightly.yml` | Daily 2AM UTC | macos-26 | Extended test suite |
| `weekly-full-ci.yml` | Sunday 3AM UTC | macos-26 | Comprehensive testing |
| `specialty-tests.yml` | Label/Manual | macos-26 | Memory/perf/stress tests |
| `release.yml` | Tag push | macos-26 | Release automation |

## Known Issues

### 1. Parallel Test Hanging
- **Symptom**: `swift test --parallel` hangs indefinitely
- **Affected Tests**: All test suites when run together
- **Workaround**: Run tests sequentially
- **Impact**: Longer CI times (~45s vs potential ~15s with parallel)

### 2. ParallelMiddlewareContextTests Crash
- **Symptom**: SIGBUS (signal 10) crash
- **Test**: `testContextForkingPerformance`
- **Status**: Test skipped, needs investigation

## Performance Benchmarks

Current CI timings (sequential):
- Build: ~30s
- Tests: ~45s
- Coverage: ~10s
- Total: ~85s per configuration

## Linux Support

Linux builds use Docker container `swift:6.1`:
- Set as `continue-on-error: true` (secondary platform)
- Requires additional system dependencies
- Uses Swift 6.1 only (no legacy version testing)

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
