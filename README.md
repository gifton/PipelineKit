# PipelineKit

A command bus for Swift 6. You describe a request as a typed `Command`, write one
`CommandHandler` for it, and run it through a pipeline that applies your middleware in a
defined order.

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-iOS%20|%20macOS%20|%20tvOS%20|%20watchOS%20|%20visionOS-lightgrey.svg)](Package.swift)
[![CI](https://github.com/gifton/PipelineKit/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/gifton/PipelineKit/actions/workflows/ci.yml?query=branch%3Amain+event%3Apush)
[![Release](https://img.shields.io/github/v/release/gifton/PipelineKit?label=release)](https://github.com/gifton/PipelineKit/releases/latest)

```
Command → Pipeline → [Middleware…] → Handler → Result
```

Retry, timeouts, circuit breaking, authentication, caching, pooling and metrics ship as
separate library products in the same package. `import PipelineKit` on its own gives you
commands, handlers, middleware and pipelines.

## A first pipeline

```swift
import PipelineKit

// A command is a value: the request, plus the type its execution returns.
struct GreetCommand: Command {
    typealias Result = String
    let name: String
}

// A handler is the logic that fulfils one command type.
struct GreetHandler: CommandHandler {
    func handle(_ command: GreetCommand, context: CommandContext) async throws -> String {
        "Hello, \(command.name)!"
    }
}

// Middleware wraps every execution. This one logs before and after.
struct LoggingMiddleware: Middleware {
    let priority: ExecutionPriority = .monitoring

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        print("-> \(T.self)")
        let result = try await next(command, context)
        print("<- \(T.self)")
        return result
    }
}

let pipeline = StandardPipeline(handler: GreetHandler())
try await pipeline.addMiddleware(LoggingMiddleware())

let greeting = try await pipeline.execute(GreetCommand(name: "world"))
print(greeting)
```

Output:

```
-> GreetCommand
<- GreetCommand
Hello, world!
```

`greeting` is a `String` because `GreetCommand.Result` is `String`; there is nothing to cast.

To run something without setting up a package (macOS 26, Swift 6.2):

```bash
git clone https://github.com/gifton/PipelineKit.git
cd PipelineKit
swift run --package-path Examples BasicExample
```

`BasicExample` is the same command, handler and pipeline without the middleware; it greets
`PipelineKit` and ends with a `PASS` line. To run the version above, add the dependency from
[Installation](#installation) to an executable package that declares
`platforms: [.macOS(.v26)]` and paste the code into its `main.swift`.

Where next:

- New to the pattern: the [command-bus book](docs/guides/command-bus/README.md), six chapters
  that build a command bus from nothing.
- Want the API tour: [Getting Started](https://gifton.github.io/PipelineKit/documentation/pipelinekit/gettingstarted/)
  on the documentation site.
- Want more runnable code: the programs in [Examples](Examples/README.md).

## Why PipelineKit

- **Results are typed.** `execute` returns the command's own `Result` type. A
  `StandardPipeline` is generic over one command and its handler.
- **Ordering is explicit.** Every middleware declares an `ExecutionPriority`. Lower values run
  first, and equal priorities keep the order they were added in.
- **It is written for Swift 6 concurrency.** The package builds in Swift 6 language mode.
  Pipelines are actors; commands, results, handlers and middleware are `Sendable`. The
  [concurrency model](docs/CONCURRENCY.md) lists the guarantees that have tests (a
  single-shot `next`, concurrent `CommandContext` access, permits conserved under
  cancellation) and names the test for each.
- **The chain is guarded.** A middleware that calls `next` a second time gets
  `PipelineError.nextAlreadyCalled` instead of running the handler twice. Middleware that
  needs to call it repeatedly, such as retry, opts out explicitly with `UnsafeMiddleware`.
- **The extras are separate products.** Resilience, security, caching, pooling and
  observability are their own modules (see [Modules](#modules)); you list only the ones you use.
- **Examples are checked in CI.** On every pull request the Swift examples in this README are
  compiled and the programs in `Examples/` are built and run. See [What is checked](#what-is-checked).

### When it is not a fit

- **You deploy below OS 26 or build with a toolchain older than Swift 6.2.** Those are the
  package's floors on every Apple platform. [Platform support](docs/platform-support.md)
  explains why.
- **You need a frozen API.** PipelineKit is 0.x: a minor release may break source, and each
  break is listed in the CHANGELOG. See [VERSIONING.md](VERSIONING.md).
- **You need Linux as a supported platform.** Linux is built on every PR but is best-effort and
  does not block CI.
- **A direct function call would do.** Every execution goes through an actor and a middleware
  chain. If you have no cross-cutting behaviour to put in middleware, that indirection buys you
  nothing. The command-bus book has a longer
  [when to use it, and when not](docs/guides/command-bus/README.md#when-to-use-command-bus-architecture) section.

## Installation

Requires Swift 6.2 or later and iOS, macOS, tvOS, watchOS or visionOS 26.0 or later
([platform support](docs/platform-support.md)).

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", "0.6.0"..<"0.7.0")
]
```

Then add the modules you need:

```swift
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            "PipelineKit",
            "PipelineKitObservability",
            "PipelineKitResilience"
        ]
    )
]
```

Keep the explicit upper bound. `from: "0.6.0"` would also accept 0.7.0, and in 0.x a minor
release may break source ([VERSIONING.md](VERSIONING.md)). For Xcode and local-checkout
setups see the [installation guide](docs/getting-started/installation.md).

## Modules

| Module | What it provides | Read more |
|---|---|---|
| `PipelineKit` | `StandardPipeline`, `DynamicPipeline`, `PipelineBuilder`, pipeline registry, debugging tools. Re-exports `PipelineKitCore`. | [API](https://gifton.github.io/PipelineKit/documentation/pipelinekit/) · [architecture](docs/guides/architecture.md) |
| `PipelineKitCore` | The protocols and core types: `Command`, `CommandHandler`, `Middleware`, `CommandContext`, `PipelineError`, `ExecutionPriority`. | [API](https://gifton.github.io/PipelineKit/documentation/pipelinekitcore/) |
| `PipelineKitResilience` | Retry, timeout, circuit breaker, bulkhead, rate limiting and back-pressure middleware. | [API](https://gifton.github.io/PipelineKit/documentation/pipelinekitresilience/) · [guide](docs/guides/resilience-patterns.md) |
| `PipelineKitSecurity` | Validation, sanitization, authentication, authorization, encryption and audit-logging middleware. | [API](https://gifton.github.io/PipelineKit/documentation/pipelinekitsecurity/) · [guide](docs/guides/security-best-practices.md) |
| `PipelineKitCache` | Result-caching middleware and cache protocols. | [API](https://gifton.github.io/PipelineKit/documentation/pipelinekitcache/) · [tutorial](docs/tutorials/custom-middleware.md) |
| `PipelineKitPooling` | Object pooling with metrics. | [API](https://gifton.github.io/PipelineKit/documentation/pipelinekitpooling/) · [guide](docs/guides/performance.md) |
| `PipelineKitObservability` | Events and metrics, with StatsD and Prometheus-format export. | [API](https://gifton.github.io/PipelineKit/documentation/pipelinekitobservability/) · [guide](docs/guides/architecture.md#observability) |
| `PipelineKitTestSupport` | Mock middleware, test commands and handlers, assertions. Add it to test targets only. | [source](Sources/PipelineKitTestSupport) |

Shipped middleware is added the same way as your own:

```swift
import PipelineKit
import PipelineKitResilience

func makeResilientPipeline<H: CommandHandler>(
    handler: H
) async throws -> StandardPipeline<H.CommandType, H> {
    let builder = PipelineBuilder(handler: handler)
    // Both run at `.resilience` priority, so insertion order decides:
    // the timeout wraps the whole retry loop.
    await builder.with(TimeoutMiddleware(defaultTimeout: 10.0))
    await builder.with(RetryMiddleware(
        maxAttempts: 3,
        strategy: .exponentialJitter(baseDelay: 1.0, maxDelay: 10.0)
    ))
    return try await builder.build()
}
```

## What is checked

- Pull requests and version tags run the same qualification workflow. macOS is built and tested
  in Debug and Release; iOS is tested on a simulator; tvOS and visionOS builds are required;
  watchOS builds are advisory. The per-platform table is in
  [platform support](docs/platform-support.md).
- The CI badge at the top reports the [`CI` workflow](.github/workflows/ci.yml) for the latest
  push to `main`: macOS Debug and Release builds, the eight test targets, a second run of the
  resilience test target (the job named `Stress Tests`), a Trivy scan for critical and high
  findings, the documentation build with its coverage floors and site deployment, and the
  tests of the CI scripts themselves. SwiftLint findings and performance-test results are
  reported there but do not fail it, and neither do its Linux build jobs. The multi-platform
  lanes above run on pull requests and release tags, so the badge does not cover them.
- A compiler-floor job builds the package and its tests with Swift 6.2.x.
- The programs in [Examples](Examples/README.md) are built and run in Debug and Release,
  and each must print its verified outcome.
- The Swift examples in this README are compiled in CI by a
  [consumer package](Tests/Integration/Consumer/Package.swift) that uses only public imports.
- Runtime dependencies are swift-atomics, swift-log and, for the security module, swift-crypto
  ([DEPENDENCIES.md](DEPENDENCIES.md)).
- Each concurrency guarantee in [docs/CONCURRENCY.md](docs/CONCURRENCY.md#guarantees-and-the-tests-that-exercise-them)
  names the test that exercises it, and a CI check fails if a named test is removed or
  renamed. Thread Sanitizer is not a gate: it runs only in the weekly and opt-in workflows.

## Performance

<!-- PROOF-SLOT(benchmarks): published benchmark numbers and their hardware/toolchain context
     are added here by the "proof" polish item. Do not add numbers in other changes. -->

This README does not publish benchmark numbers yet. To measure on your own hardware,
[docs/benchmarks.md](docs/benchmarks.md) describes the Release-mode harness, its four workloads
and how to compare a candidate against a baseline. The XCTest `measure` suites are also
available:

```bash
swift test -c release --filter PipelineKitPerformanceTests
```

For tuning advice see the [performance guide](docs/guides/performance.md).

## Documentation

| If you want to | Go to |
|---|---|
| Browse the API reference for the seven library modules | [gifton.github.io/PipelineKit](https://gifton.github.io/PipelineKit/) |
| Learn the command-bus pattern from first principles | [Command-bus book](docs/guides/command-bus/README.md) |
| Work through tutorials | [Basic usage](docs/tutorials/basic-usage.md), [custom middleware](docs/tutorials/custom-middleware.md), [advanced patterns](docs/tutorials/advanced-patterns.md) |
| Understand how the pieces fit | [Architecture guide](docs/guides/architecture.md) |
| Evaluate it for adoption | [Evaluating PipelineKit](docs/guides/enterprise-evaluation.md) |
| See everything | [Documentation index](docs/README.md) |

## Stability and versioning

PipelineKit is in the 0.x series. Patch releases do not break source. Minor releases may, and
every source-breaking change is listed under a **Breaking** heading in the
[CHANGELOG](CHANGELOG.md). There is no deprecation window in 0.x. The full policy, including the
criteria for 1.0, is in [VERSIONING.md](VERSIONING.md).

**Upgrading from 0.5.4:** 0.6.0 includes source and behavior changes. Follow the
[compiled stabilization migration guide](docs/migrations/first-stabilization-batch.md) before
upgrading, including cache invalidation and old encrypted-data recovery limits, and review the
[release-readiness migration notes](docs/migrations/release-readiness.md).

To report a security vulnerability, see [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the
development setup, test workflow, and PR conventions. All participation is governed
by the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

PipelineKit is released under the MIT License. See [LICENSE](LICENSE) for details.
