# Architecture

How commands, handlers, middleware, and pipelines fit together.

## Overview

PipelineKit is a command-bus architecture built on Swift actors and
structured concurrency. Every execution follows the same path:

1. A `Command` value enters a pipeline.
2. The pipeline invokes its middleware chain in `ExecutionPriority` order.
3. The innermost call reaches the `CommandHandler`, which produces the
   command's `Result` (or throws).
4. The result unwinds back out through the same middleware, giving each
   one a chance to observe or transform the outcome.

A `CommandContext` travels with the execution, carrying typed key/value
state, metadata, and capability handles (such as a progress reporter) that
middleware and the handler can read.

### Middleware ordering

Each middleware declares an `ExecutionPriority`. Lower raw values sit
*outer* in the chain — they run first on the way in and last on the way
out. The standard priorities, in chain order:

| Priority | Raw value |
| --- | --- |
| `authentication` | 100 |
| `validation` | 200 |
| `resilience` | 250 |
| `preProcessing` | 300 |
| `monitoring` | 350 |
| `processing` | 400 |
| `postProcessing` | 500 |
| `errorHandling` | 600 |
| `observability` | 700 |
| `custom` | 1000 |

One practical consequence: a retry middleware at `.resilience` (250) wraps
a timing middleware at `.monitoring` (350), so the timing middleware runs
once per retry attempt.

### Pipeline implementations

- ``StandardPipeline`` — the primary implementation: an actor generic over
  one command/handler pair.
- ``AnyStandardPipeline`` — type-erased variant accepting any command type.
- ``DynamicPipeline`` — routes commands to handlers registered at runtime.
- ``PipelineBuilder`` — fluent builder for assembling a ``StandardPipeline``.

### Modules

| Module | Provides |
| --- | --- |
| `PipelineKit` (umbrella) | Pipelines, registry, debugging tools; re-exports `PipelineKitCore`. |
| `PipelineKitCore` | Core protocols and types: `Command`, `CommandHandler`, `Middleware`, `CommandContext`, `PipelineError`, `ExecutionPriority`. |
| `PipelineKitSecurity` | Validation, authentication/authorization, encryption, and audit-logging middleware. |
| `PipelineKitResilience` | Retry, timeout, circuit-breaker, bulkhead, rate-limiting, and back-pressure middleware. |
| `PipelineKitCache` | Result-caching middleware and cache protocols. |
| `PipelineKitPooling` | Object pooling with metrics. |
| `PipelineKitObservability` | Events, metrics (StatsD/Prometheus export), and in-process execution tracing. |

All targets build with strict concurrency enabled; public types are
`Sendable`, and pipelines are actors.
