# Release qualification changes

This change prepares the current branch for release qualification. It does not
select a version or create a release. The API changes below require caller updates.

## Middleware test controls

Use `PipelineTestUtils.createTestPipeline(handler:middleware:)` to create a
`TestPipeline` with middleware interception. An arbitrary pipeline wrapped with
`TestPipeline(basePipeline:)` supports execution recording; attempts to configure
interception throw `TestPipelineError.interceptionUnavailable`.

Replace the former untyped mock closure with
`try await pipeline.mockMiddleware(MyMiddleware.self, for: MyCommand.self) { command in ... }`.
The closure accepts `MyCommand` and returns `MyCommand.Result`. The middleware type
must be registered with the factory, and the command type must match its handler.
An unknown middleware or mismatched command type throws a configuration error.

Add `try` to `delayMiddleware(_:delay:)` and `failMiddleware(_:after:)` calls.
Delays must be finite, nonnegative, and representable in nanoseconds; failure counts
must be nonnegative. `after: n` permits the first `n` matching middleware entries,
then injects a failure on every later entry until reset or reconfiguration. Repeated
instances of the same middleware type share the count.

Interception applies a cancellable delay first, then failure injection, then the
mock or original middleware. A mock returns in place of the selected middleware
and its downstream chain. Inactive conditional middleware does not enter interception.
`reset()` clears settings and creates a recorder for new executions; already admitted
executions retain their settings and finish recording in their original recorder.

`TestPipeline` finishes the progress reporter explicitly attached to its invocation's
`CommandContext` on success, failure, or cancellation before admission. A reporter
inherited from a parent execution remains open for that parent.

When NextGuard warnings are enabled, `TestPipeline` preserves missing-`next`
diagnostics from original middleware executed without a mock. Actual mocks and
injected failures do not produce those warnings. Original explicit warning
suppression and `UnsafeMiddleware` behavior are preserved.

Shared delay helpers now reject negative, nonfinite, or nanosecond-unrepresentable
delays with `TestPipelineError.invalidDelay`: `AsyncTestCommand.execute()`,
`AsyncTestCommandHandler.handle`, `DelayMiddleware` (including
`MockMiddlewareFactory.delay` and `simulatingTimeout`), and
`MockCommandProcessor.process`. The nonthrowing
`MockEventSubscriber(processingDelay:)` initializer enforces the same constraint
as a precondition for non-nil delays; `nil` disables its delay. Zero is allowed,
and positive delays below one nanosecond truncate to zero. These helper corrections
do not change public signatures.

## Rate-limit status failures

`RateLimiter.getStatus(identifier:priority:)` is now `async throws`. Change status
reads to `try await limiter.getStatus(...)` and handle backing-store errors.
Distributed status lookups propagate the store's error, including cancellation,
instead of returning a fabricated empty count or available quota.

`SecureCommandDispatcher.getRateLimitStatus(userID:commandType:)` also requires `try await`.
Its optional result is `nil` when no rate limiter is configured; a failed status
lookup throws. See the updated [rate policy example](resilience-policy-contracts.md#rate-limit-priority-and-reset).

## Removed unfinished profiler

`MemoryProfiler`, its nested snapshot/allocation/report types, `MemoryPattern`, and
the global `memoryProfiler` have been removed. Remove those references from clients.
This change introduces no replacement profiling API. Memory-pressure detection and
memory-pressure response remain separate APIs.

## Supported installation and retry usage

Use the package products described in the [installation guide](../getting-started/installation.md).
Copying only `Sources/PipelineKit` omits required sibling modules and dependencies.
Local development uses a local Swift package checkout with its manifest intact.

The [async tutorial](../tutorials/basic-usage.md#async-command-processing) now imports
`PipelineKitResilience` and uses the shipped `RetryMiddleware`. Its `maxAttempts: 2`
means two retries after the initial call. Ordinary `Middleware` has a single-call
`next` contract and cannot implement that loop itself.

The documentation extractor includes the corrected tutorial. The external consumer's
`policy-contract` mode invokes the exact documented retry factory through a guarded
middleware using `StandardPipeline`, `PipelineBuilder`, and `DynamicPipeline`.
The dynamic route uses `send(..., retryPolicy: .none)` so the middleware owns the
retry budget and an outer policy cannot restart the entire retry sequence.
For each route it checks recovery on the second attempt, exhaustion after three
attempts, a nonretryable transport error, and cancellation, including handler and
guarded-middleware traversal counts. Network requests in the tutorial's usage fence
are compiled only; the behavioral consumer supplies an in-process handler.

## CI coverage and registry lifecycle

The main and multiplatform CI workflows include `release/**` pushes and pull
requests, including changes limited to documentation. Coverage collection preserves
profiles from all eight correctness suites outside SwiftPM's managed coverage
directory. Missing profiles, merge/export failures, and missing coverage upload
artifacts fail the coverage run.
Coverage reports are retained as GitHub Actions artifacts: `coverage-ci-macos`
in the main workflow and `coverage-macos` in the multiplatform workflow. No
external coverage service or upload credential is required. The existing
percentage-threshold policy is unchanged.

`PoolRegistry` starts maintenance when a pool is registered. Tests now explicitly
own their registries and await the internal `shutdownAndWait()` in async teardown.
That method waits for maintenance to settle and rejects later registration. The
public synchronous `PoolRegistry.shutdown()` retains its 100 ms best-effort wait
and may return before maintenance settles. Merely reading registry statistics
does not start maintenance.

## Qualification boundaries

The [validation instructions](../../Scripts/validation/README.md) describe the Debug,
Release, public consumer, numeric, protocol, and watchdog checks. A passing run must
be read together with its reported skips and platform conditions. The table below
inventories explicit skip sites in the repository tests; it is not a claim that
every listed test was executed during a particular run.

| Skip condition | Tests or source | Disposition |
| --- | --- | --- |
| Replaced external HTTP placeholders | `HealthCheckMiddlewareTests.testHTTPHealthCheckWithValidEndpoint`, `testHTTPHealthCheckWithServerError`, `testHTTPHealthCheckWithClientError` | These now run with per-session URLProtocol fixtures through the real HTTP health-check implementation. Additional tests cover unexpected/custom status codes, non-HTTP responses, transport errors, request timeout forwarding, and in-flight cancellation. They do not qualify an external service. |
| Always skipped integration placeholder | `BackPressureMiddlewareTests.testRateLimitIntegration` | Built-in rate limiting in this backpressure example remains unimplemented. Its old message is broader than the actual gap: separate `RateLimiter` and rate-limiting middleware APIs do exist. |
| CI and simulator timing exclusions | `SimpleSemaphoreCancellationTests.testCancellationWithMultiplePermits`, `TimeoutMiddlewareTests.testTimeoutMiddlewareWithCommandSpecificTimeout`, `TimeoutProofTests.testTimeoutCorrectlyEnforcesWhenSlowOperationIsAfter`, `ResilientMiddlewareTests.testExponentialBackoffRetry` | These scheduler-dependent assertions run only outside those conditions. Deterministic contract tests and the public consumer cover specific related behavior, but do not erase these exclusions. |
| CI timing exclusion | `BackPressureMiddlewareTests.testStatsAccuracy` | This timing-based statistics scenario remains excluded when `CI=true`. |
| Simulator performance exclusions | `MiddlewareTests.testMiddlewarePerformance`, `PipelineTests.testPipelinePerformance`, `SecurityPolicyMiddlewareTests.testPolicyValidationPerformance`, `OptimizedValidatorsTests.testPerformanceComparison` | Absolute throughput/wall-time assertions are excluded on simulators. They provide no simulator performance qualification. |
| Simulator benchmark class exclusions | `ActorVsLockBenchmark`, `CoreValuePerformanceTests`, `SecurityValidationPerformanceTests`, `CommandContextPerformanceTests`, `SimpleCachingPerformanceTests`, `PipelinePerformanceTests`, `ObservabilityPerformanceTests`, `BackPressurePerformanceTests` | Class setup skips measurements on simulators. The separate performance suite remains advisory and is excluded from the ordinary correctness lane. |
| Isolated numeric probe | `CompressionMiddlewareTests.testCompressionSizeNumericConfigurationProbe` | The ordinary suite skips this test without probe environment variables. `check_numeric_boundaries.py` runs it in separate processes with accepted/rejected controls. |
| Dormant timeout helper | `Tests/PipelineKitObservabilityTests/TestHelpers.swift`, `withTimeout(seconds:operation:)` | The helper converts timeout into `XCTSkip` and has no current call sites in that target. It is not used as qualification evidence and must be corrected before reuse as a correctness timeout guard. |

No dashboard or general-purpose allocation profiler is completed by this batch.
