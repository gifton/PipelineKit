# PipelineKit tests

How to run the tests is in [CONTRIBUTING.md](../CONTRIBUTING.md#running-tests). What CI runs is
in the README's [What is checked](../README.md#what-is-checked) section and, per platform, in
[platform support](../docs/platform-support.md).

## Layout

| Directory | What it tests |
| --- | --- |
| [PipelineKitCoreTests](PipelineKitCoreTests) | `PipelineKitCore`: commands, `CommandContext`, errors, the middleware protocol, `ExecutionContext`, progress reporting |
| [PipelineKitTests](PipelineKitTests) | `PipelineKit`: pipelines, the registry, cancellation, `NextGuard`, debugging tools |
| [PipelineKitResilienceTests](PipelineKitResilienceTests) | `PipelineKitResilience` |
| [PipelineKitSecurityTests](PipelineKitSecurityTests) | `PipelineKitSecurity` |
| [PipelineKitObservabilityTests](PipelineKitObservabilityTests) | `PipelineKitObservability` |
| [PipelineKitCacheTests](PipelineKitCacheTests) | `PipelineKitCache` |
| [PipelineKitPoolingTests](PipelineKitPoolingTests) | `PipelineKitPooling` |
| [PipelineKitTestSupportTests](PipelineKitTestSupportTests) | `PipelineKitTestSupport` itself |
| [PipelineKitPerformanceTests](PipelineKitPerformanceTests) | XCTest `measure` suites. Run them explicitly, in Release; see [benchmarks](../docs/benchmarks.md) |
| [Integration/Consumer](Integration/Consumer) | A standalone package that uses only public imports. It compiles the Swift examples extracted from the documentation and holds the public-API checks that CI runs in Debug and Release. It is not part of `swift test` at the repository root |

Every directory except `Integration` is a test target in the root `Package.swift`.

## Writing tests

- Put a test in the target for the module it exercises.
- `PipelineKitTestSupport` ([source](../Sources/PipelineKitTestSupport)) provides test commands
  and handlers, mock middleware, `TestPipeline` and assertion helpers. It is a library product,
  so packages that depend on PipelineKit can use it in their own test targets.
- A guarantee stated in [docs/CONCURRENCY.md](../docs/CONCURRENCY.md) names the test that
  exercises it, and a CI check fails if that test is renamed or removed. Update the document
  in the same change.
