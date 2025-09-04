# CI Configuration Notes

## Important Configuration Decisions

### 1. Parallel Test Execution Disabled
- **Issue**: Tests hang when run with `--parallel` flag
- **Solution**: Removed `--parallel` from all test commands
- **Files**: `simple-ci.yml`, `ci.yml`
- **TODO**: Investigate root cause - likely related to actor isolation or semaphore deadlocks

### 2. Job Dependencies Removed
- **Issue**: `needs: build` caused unnecessary job queuing
- **Solution**: Removed dependencies between build and test jobs
- **Benefit**: Jobs run in parallel, reducing total CI time
- **Trade-off**: Slightly higher resource usage

### 3. Coverage Generation
- **Issue**: Version mismatch between Swift compiler and system llvm-cov
- **Solution**: Use llvm-cov from Swift toolchain
- **Implementation**: Extract toolchain path and use its llvm-cov

### 4. NextGuard Warning Configuration
- **Default**: Timeout warnings are automatically suppressed
- **Optional**: Set `PIPELINEKIT_DISABLE_NEXTGUARD_WARNINGS=1` to disable all warnings
- **Current**: Using defaults (warnings enabled but timeout false positives suppressed)

## Environment Variables

| Variable | Purpose | Required | Default |
|----------|---------|----------|---------|
| `SWIFT_VERSION` | Swift version for builds | Yes | 6.0 |
| `BENCHMARK_DISABLE_JEMALLOC` | Disable jemalloc in benchmarks | Yes | 1 |
| `PIPELINEKIT_DISABLE_NEXTGUARD_WARNINGS` | Disable NextGuard warnings | No | unset |

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
- Total: ~85s per matrix configuration

With parallel tests (if fixed):
- Potential improvement: ~30s faster

## Maintenance Notes

1. **Swift Version Updates**: Update `SWIFT_VERSION` in env and `swift-version` in setup
2. **New Test Targets**: Add to filter list in `ci.yml` line 62
3. **Coverage**: Only generated for `macos-14` with Swift 6.0 to save time
4. **Benchmarks**: Using XCTest performance tests instead of package-benchmark

## Troubleshooting

### Tests Failing in CI but Passing Locally
1. Check for timing-sensitive tests
2. Verify environment variables match
3. Consider CI hardware differences (slower/different architecture)

### Coverage Upload Failures
1. Verify `CODECOV_TOKEN` secret is set
2. Check that test binary exists at expected path
3. Ensure profdata was generated with `--enable-code-coverage`

### Benchmark Timeouts
1. Current timeout: 10 minutes
2. If benchmarks timeout, consider reducing iterations
3. Or split into smaller benchmark suites

## Future Improvements

1. **Fix parallel test execution** - Investigate and resolve hanging issue
2. **Add benchmark regression detection** - Compare results against baseline
3. **Matrix strategy optimization** - Consider if we need all OS versions
4. **Caching improvements** - Cache Swift toolchain installation
5. **Add performance gates** - Fail if performance degrades significantly