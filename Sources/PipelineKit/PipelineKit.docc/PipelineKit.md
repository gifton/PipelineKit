# ``PipelineKit``

A comprehensive Swift framework for building secure, observable, and resilient command execution pipelines.

## Overview

PipelineKit provides a robust foundation for implementing the Command pattern with a flexible middleware pipeline. It's designed for building scalable, maintainable applications with cross-cutting concerns like authentication, validation, rate limiting, and observability.

### Key Features

- **Command Pattern**: Encapsulate operations as reusable command objects
- **Middleware Pipeline**: Compose behaviors through a configurable middleware chain
- **Thread-Safe Context**: Propagate metadata and cross-cutting concerns safely
- **Comprehensive Security**: Built-in validation, sanitization, and encryption
- **Observability**: Detailed tracing, metrics, and performance monitoring
- **Resilience**: Retry policies, circuit breakers, and error recovery
- **Memory Efficient**: Object pooling and optimized execution paths

## Topics

### Essentials

- <doc:GettingStarted>
- ``Command``
- ``Middleware``
- ``CommandContext``
- ``CommandDispatcher``

### Building Pipelines

- ``PipelineBuilder``
- ``ExecutionPriority``
- <doc:MiddlewareComposition>
- <doc:PipelineDSL>

### Architecture Patterns

- <doc:ChoosingArchitecture>
- ``CommandBus``
- ``Pipeline``

### Error Handling

- ``PipelineError``
- ``ErrorRecovery``
- <doc:ErrorHandlingStrategies>

### Security

- <doc:SecurityOverview>
- ``ValidationMiddleware``
- ``SanitizationMiddleware``
- ``SecurityPolicy``

### Middleware Catalog

- <doc:AuthenticationMiddleware>
- <doc:RateLimitingMiddleware>
- <doc:CachingMiddleware>
- <doc:ResilientMiddleware>
- <doc:MetricsMiddleware>

### Advanced Topics

- <doc:PerformanceOptimization>
- <doc:MemoryManagement>
- <doc:CustomMiddleware>
- <doc:TestingStrategies>