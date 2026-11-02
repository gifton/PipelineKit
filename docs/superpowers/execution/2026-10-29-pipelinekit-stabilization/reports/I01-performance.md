# I01 Release performance observation

One required run: `swift test -c release --filter PipelineKitPerformanceTests` (I01-027), 19 tests passed. Apple M3 Max, 16 physical/logical CPUs, 48 GiB RAM; macOS 27.0.1 arm64, Swift 6.4.2, Xcode 27.2. Full samples, CPU/memory/disk data and source line locations are in [I01-performance.json](I01-performance.json).

No explicit application warm-up loop exists in the measured fixtures. XCTest internal warm-up was not independently instrumented; raw sample counts, including first recorded sample, are retained.

Pipeline: 1000 sends per sample, 0/1/5 pass-through middleware and 1000 concurrent tasks; baseline-options case 100 sends. Actor/lock microbenchmarks: 200000 ticks across 64 tasks. Context: 10000 get/set/mixed operations, 2x5000 concurrent accesses, 1000 creations and 1000-entry lookup. Semaphore fixtures: 10000 sequential acquisitions, 1000 contending tasks, 5000 objects for footprint; see exact hashed fixtures.

| Workload (test method) | Samples | Median seconds | Observed min–max seconds |
|---|---:|---:|---:|
| testActorThroughputUnderContention | 5 | 0.067876 | 0.067284–0.068536 |
| testLockThroughputUnderContention | 5 | 0.001186 | 0.001147–0.001485 |
| testContendedAccessPerformance | 5 | 0.003137 | 0.002931–0.003357 |
| testFailedAcquirePerformance | 5 | 0.000255 | 0.000247–0.000268 |
| testHighConcurrencyPerformance | 5 | 0.004203 | 0.004062–0.005071 |
| testTryAcquirePerformance | 5 | 0.017273 | 0.016534–0.017972 |
| testUncontendedAcquirePerformance | 5 | 0.015505 | 0.015444–0.015800 |
| testConcurrentMetadataAccessPerformance | 5 | 0.202328 | 0.197411–0.208401 |
| testContextCreationPerformance | 5 | 0.000393 | 0.000391–0.000402 |
| testGetMetadataPerformance | 5 | 0.002421 | 0.002367–0.003772 |
| testLargeContextPerformance | 5 | 0.012600 | 0.012567–0.012784 |
| testMixedMetadataOperationsPerformance | 5 | 0.164118 | 0.163805–0.165562 |
| testSetMetadataPerformance | 5 | 0.649821 | 0.647162–0.656395 |
| testBaselineOptions | 10 | 0.000161 | 0.000153–0.000187 |
| testConcurrentPipelineExecutionPerformance | 5 | 0.002888 | 0.002555–0.003130 |
| testPipelineWithMultipleMiddlewarePerformance | 5 | 0.002220 | 0.002123–0.002281 |
| testPipelineWithSingleMiddlewarePerformance | 5 | 0.001453 | 0.001420–0.001486 |
| testSimplePipelineExecutionPerformance | 5 | 0.001283 | 0.001219–0.001324 |

No before/after performance baseline or unchanged-throughput claim; LS-010 stays open.

R04 health queries scan retained history O(n); these benchmarks do not measure that cost.

Physical memory/CPU/disk metrics are retained where emitted; not allocation counts.

No thermal/load control or independent warm-up instrumentation. Five-sample ranges/medians are descriptive, not tail-latency estimates.

Existing concurrent benchmark discarded outcomes and unstructured task limitations are not repaired by a passing measurement.
