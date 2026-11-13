# Testing code that uses PipelineKit

`PipelineKitTestSupport` is a library product with test doubles and assertions for code built
on PipelineKit. Add it to test targets only:

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", "0.6.0"..<"0.7.0")
],
targets: [
    .testTarget(
        name: "YourAppTests",
        dependencies: [
            .product(name: "PipelineKit", package: "PipelineKit"),
            .product(name: "PipelineKitTestSupport", package: "PipelineKit")
        ]
    )
]
```

The module is not on the documentation site. Its reference is the doc comments in
[Sources/PipelineKitTestSupport](../../Sources/PipelineKitTestSupport).

## What it provides

| To | Use | Defined in |
|---|---|---|
| Run a handler through real middleware and record each execution | `PipelineTestUtils.createTestPipeline(handler:middleware:)`, which returns a `TestPipeline`; `getRecorder()` reports success and failure counts | `TestPipeline.swift` |
| Replace one middleware and the rest of its chain with a result, delay it, or fail it after a number of calls | `mockMiddleware(_:for:handler:)`, `delayMiddleware(_:delay:)`, `failMiddleware(_:after:)`; `reset()` clears them | `TestPipeline.swift` |
| Assert on one execution | `assertPipelineSucceeds(_:equals:)`, `assertPipelineFails(_:with:)`, `assertCompletesWithin(_:_:)`, `assertTakesAtLeast(_:_:)` | `PipelineAssertions.swift` |
| Get a ready-made middleware | `MockMiddlewareFactory`: `logger()`, `counter()`, `delay(_:)`, `failing(with:)`, `failingWhen(_:)`, `modifying(_:)` | `MockMiddlewareFactory.swift` |
| Count or order events across tasks | `TestCounter`, `ExecutionOrderTracker` | `TestCounter.swift` |
| Start from sample commands and handlers | `TestCommand` and `TestCommandHandler`, `MockCommand` and `MockCommandHandler` | `TestHelpers.swift`, `Mocks/MockTypes.swift` |

A `TestPipeline` created with `TestPipeline(basePipeline:)` only records: its middleware is
opaque, so the three interception methods throw `TestPipelineError`.

## A compiled example

[`PublicTestPipelineTests.swift`](../../Tests/Integration/Consumer/Tests/ConsumerTests/PublicTestPipelineTests.swift)
uses the module through public imports only. It builds a `TestPipeline`, replaces a
middleware's result, resets, injects a failure, and checks that a recording-only wrapper
rejects interception. CI runs it in Debug and Release.

For what to test at which level, see
[chapter 6 of the command-bus book](command-bus/06-TestingTheBus.md).
