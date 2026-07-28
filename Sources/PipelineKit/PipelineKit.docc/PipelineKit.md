# ``PipelineKit``

A type-safe, actor-based command pipeline framework for Swift.

## Overview

PipelineKit routes strongly typed commands through an ordered middleware
chain to a single handler, on top of Swift structured concurrency. You
define a `Command` (with an associated `Result` type), a `CommandHandler`
that contains the business logic, and compose cross-cutting concerns —
validation, retry, timeouts, metrics, caching — as `Middleware` ordered by
`ExecutionPriority`.

The `PipelineKit` module is the umbrella: it defines the pipeline
implementations, registry, and debugging tools documented here, and
re-exports everything from `PipelineKitCore` (protocols such as `Command`,
`CommandHandler`, `Middleware`, and the `CommandContext` type), so
`import PipelineKit` is the only import most applications need.

The package also ships six focused modules, published alongside this one:
`PipelineKitCore`, `PipelineKitSecurity`, `PipelineKitResilience`,
`PipelineKitCache`, `PipelineKitPooling`, and `PipelineKitObservability`.

For a from-scratch tutorial on the command-bus pattern itself (independent
of PipelineKit's API), see the
[command-bus book](https://github.com/gifton/PipelineKit/tree/main/docs/guides/command-bus).

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Architecture>

### Pipelines

- ``StandardPipeline``
- ``AnyStandardPipeline``
- ``DynamicPipeline``
- ``PipelineBuilder``

### Pipeline Registry

- ``PipelineRegistry``
- ``PipelineKey``
- ``RegistryStats``

### Debugging and Inspection

- ``ExecutionRecorder``
- ``ExecutionRecord``
- ``RecordingMiddleware``
- ``PipelineInspector``
- ``PipelineInfo``
- ``MiddlewareDetail``
- ``ExecutionTrace``

### Pipeline Visualization

- ``PipelineDescription``
- ``MiddlewareInfo``
- ``VisualizationOptions``

### Middleware Composition

- ``MiddlewareOrderBuilder``

### Concurrency Utilities

- ``NextGuard``
- ``NextGuardConfiguration``
- ``SemaphoreToken``
- ``SimpleSemaphore``
