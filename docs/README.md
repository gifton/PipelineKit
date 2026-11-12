# PipelineKit documentation

Start at the [repository README](../README.md): it has a first pipeline and the install snippet.
This page says where everything else is, and in what order to read it.

## Two reading paths

**Learning the pattern.** For readers who want the idea first and real code second.

1. The README's [first pipeline](../README.md#a-first-pipeline); run `BasicExample` as it
   describes.
2. The [command-bus book](guides/command-bus/README.md): six chapters that build a small bus
   from nothing and end with how its parts map onto PipelineKit.
3. The tutorials: [basic usage](tutorials/basic-usage.md), then
   [custom middleware](tutorials/custom-middleware.md).
4. The programs in [Examples](../Examples/README.md): run them, then change them.
5. The [architecture guide](guides/architecture.md) and the
   [API reference](https://gifton.github.io/PipelineKit/), to see how the shipped types fit.

**Building a pipeline for throughput.** For engineers structuring a high-volume workload.

1. The README's [when it is not a fit](../README.md#when-it-is-not-a-fit) and
   [what is checked](../README.md#what-is-checked).
2. On the documentation site,
   [Getting Started](https://gifton.github.io/PipelineKit/documentation/pipelinekit/gettingstarted/)
   and [Architecture](https://gifton.github.io/PipelineKit/documentation/pipelinekit/architecture/),
   which has the middleware ordering table.
3. [Understanding concurrency controls](guides/resilience-patterns.md#understanding-concurrency-controls)
   and the [performance guide](guides/performance.md).
4. The programs in [Examples](../Examples/README.md).
5. The evidence: [tested concurrency guarantees](CONCURRENCY.md#guarantees-and-the-tests-that-exercise-them)
   and the [published measurements](benchmarks.md), with how to repeat them on your own hardware.

## Where things live

| Surface | What it holds |
|---|---|
| [README](../README.md) | The front door: what PipelineKit is, a first pipeline, installation, the module map, what CI checks. |
| [Documentation site](https://gifton.github.io/PipelineKit/) | The API reference for the seven library modules, generated from source, and four articles about how the API fits together: Getting Started, Architecture, Middleware Guide, Execution Context and Progress Reporting. |
| `docs/` (this tree) | Everything read at length: the book, tutorials, task guides, and the evidence and policy pages. |
| [Examples](../Examples/README.md) | Programs that CI builds and runs, each checking its own output. |

Each topic has one home. Another surface may summarise it in a few lines and link to it; it
repeats a code sample only where that copy is also compiled in CI.

## All pages

| Page | What it covers |
|------|----------------|
| **Learn** | |
| [guides/command-bus/](guides/command-bus/README.md) | The command-bus book: the pattern from first principles, with a teaching implementation |
| [tutorials/basic-usage.md](tutorials/basic-usage.md) | Commands, handlers, context, errors, validation and retry with the real API |
| [tutorials/custom-middleware.md](tutorials/custom-middleware.md) | Writing middleware; the shipped rate-limiting, caching and observer middleware |
| [tutorials/advanced-patterns.md](tutorials/advanced-patterns.md) | Conditional middleware, environment-specific pipelines, composition |
| **Guides** | |
| [getting-started/installation.md](getting-started/installation.md) | Swift Package Manager and Xcode setup, version ranges, local checkouts |
| [migrations/0.5-to-0.6.md](migrations/0.5-to-0.6.md) | Upgrading from 0.5.4 to 0.6.0: source, behavior and stored-data changes by module |
| [guides/architecture.md](guides/architecture.md) | The core types in more depth, and usage guidelines |
| [guides/resilience-patterns.md](guides/resilience-patterns.md) | Rate limiting, circuit breakers, bulkheads, back-pressure, timeouts, retries, and how to order them |
| [guides/performance.md](guides/performance.md) | Reusing pipelines, concurrency limits, pooling |
| [guides/security-best-practices.md](guides/security-best-practices.md) | Hardening an application: validation, authorization, rate limiting, encryption, audit logging |
| [guides/testing.md](guides/testing.md) | Testing code that uses PipelineKit with `PipelineKitTestSupport` |
| **Evidence and policy** | |
| [CONCURRENCY.md](CONCURRENCY.md) | The concurrency model, and each guarantee with the test that exercises it |
| [benchmarks.md](benchmarks.md) | Published 0.6.0 results with their records, the measurement harness and its workloads, and how to collect and compare runs |
| [platform-support.md](platform-support.md) | Platform floors, what CI verifies per platform, Linux status |
| [guides/enterprise-evaluation.md](guides/enterprise-evaluation.md) | A 30-minute proof of concept, stable versus newer API, where to report issues |

Project-level documents live at the repository root: [CHANGELOG](../CHANGELOG.md),
[CONTRIBUTING](../CONTRIBUTING.md), [CODE_OF_CONDUCT](../CODE_OF_CONDUCT.md),
[SECURITY](../SECURITY.md), [DEPENDENCIES](../DEPENDENCIES.md),
[VERSIONING](../VERSIONING.md).
