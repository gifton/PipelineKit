# Choosing Between DynamicPipeline and Pipeline

Learn when to use DynamicPipeline for centralized routing versus Pipeline for direct execution.

## Overview

PipelineKit provides two architectural patterns for command execution, each optimized for different use cases. Understanding when to use each pattern is crucial for building maintainable applications.

## Architectural Comparison

### Pipeline: Direct Execution

Pipelines provide direct, type-safe command execution with dedicated middleware chains:

```swift
// Each pipeline handles one specific command type
let pipeline = PipelineBuilder(handler: CreateUserHandler())
    .with(ValidationMiddleware())
    .with(AuthorizationMiddleware())
    .build()

// Direct execution with compile-time type safety
let user = try await pipeline.execute(CreateUserCommand(email: "user@example.com"))
```

**Key Characteristics:**
- One pipeline per command type
- Compile-time type safety
- Lower execution overhead (~0.006ms)
- Explicit handler binding
- Independent middleware configuration

### DynamicPipeline: Centralized Routing

DynamicPipeline provides a single entry point for multiple command types with dynamic routing:

```swift
// One pipeline handles multiple command types
let pipeline = DynamicPipeline()
await pipeline.register(CreateUserCommand.self, handler: CreateUserHandler())
await pipeline.register(UpdateUserCommand.self, handler: UpdateUserHandler())
await pipeline.register(DeleteUserCommand.self, handler: DeleteUserHandler())

// Dynamic routing based on command type
let result = try await pipeline.send(command) // Any registered command
```

**Key Characteristics:**
- Single dispatcher for all commands
- Runtime type resolution
- Slightly higher overhead (~0.008ms)
- Dynamic handler registration
- Shared middleware for all commands

## Decision Guide

### Use Pipeline When:

✅ **Building microservices** with single responsibilities
- Each service handles specific command types
- Clear boundaries between services
- Type safety is critical

✅ **Performance is critical**
- Lower latency requirements
- High-throughput scenarios
- Minimal overhead needed

✅ **You need fine-grained control**
- Different middleware per command
- Custom execution strategies
- Specific optimization needs

✅ **Building libraries or frameworks**
- Clear, explicit APIs
- No hidden abstractions
- Predictable behavior

### Use DynamicPipeline When:

✅ **Building API gateways**
- Single entry point for multiple operations
- Dynamic command routing needed
- Request/response abstraction

✅ **Working with plugin architectures**
- Runtime handler registration
- Dynamic service discovery
- Extensible command handling

✅ **You need centralized control**
- Consistent middleware for all commands
- Global circuit breakers
- Unified monitoring

✅ **Building monolithic applications**
- Many command types in one codebase
- Shared infrastructure concerns
- Simplified dependency injection

## Real-World Examples

### Microservice Architecture (Pipeline)

```swift
// Payment Service - dedicated pipeline
class PaymentService {
    private let pipeline = PipelineBuilder(handler: PaymentHandler())
        .with(SecurityMiddleware())
        .with(ValidationMiddleware())
        .with(AuditMiddleware())
        .build()
    
    func processPayment(_ command: PaymentCommand) async throws -> PaymentResult {
        return try await pipeline.execute(command)
    }
}

// User Service - separate pipeline
class UserService {
    private let pipeline = PipelineBuilder(handler: UserHandler())
        .with(AuthenticationMiddleware())
        .with(CacheMiddleware())
        .build()
    
    func getUser(_ command: GetUserCommand) async throws -> User {
        return try await pipeline.execute(command)
    }
}
```

### API Gateway (DynamicPipeline)

```swift
// Centralized command routing for all services
class APIGateway {
    private let pipeline = DynamicPipeline()
    
    init() async {
        // Register all service handlers
        await pipeline.register(PaymentCommand.self, handler: PaymentHandler())
        await pipeline.register(GetUserCommand.self, handler: UserHandler())
        await pipeline.register(OrderCommand.self, handler: OrderHandler())
        
        // Apply cross-cutting concerns to all
        await pipeline.addMiddleware(AuthenticationMiddleware())
        await pipeline.addMiddleware(LoggingMiddleware())
        await pipeline.addMiddleware(RateLimitingMiddleware())
    }
    
    // Single method handles all command types
    func handle<T: Command>(_ command: T) async throws -> T.Result {
        return try await pipeline.send(command)
    }
}
```

## Hybrid Approach

You can combine both patterns for maximum flexibility:

```swift
// Use pipelines for internal services
class InternalServices {
    let paymentPipeline = PipelineBuilder(handler: PaymentHandler()).build()
    let userPipeline = PipelineBuilder(handler: UserHandler()).build()
}

// Expose via DynamicPipeline for external API
class PublicAPI {
    private let pipeline = DynamicPipeline()
    private let services = InternalServices()
    
    init() async {
        // Wrap pipelines in dynamic pipeline for unified access
        await pipeline.register(PaymentCommand.self) { command in
            try await services.paymentPipeline.execute(command)
        }
        await pipeline.register(GetUserCommand.self) { command in
            try await services.userPipeline.execute(command)
        }
    }
}
```

## Performance Considerations

### Execution Overhead
- **Pipeline**: ~0.006ms per command (baseline)
- **DynamicPipeline**: ~0.008ms per command (+33% overhead)

### Memory Usage
- **Pipeline**: Handler + middleware array per pipeline
- **DynamicPipeline**: Additional routing table + handler registry

### Scalability
- **Pipeline**: Linear with number of command types
- **DynamicPipeline**: Constant regardless of command types


## Summary

- Use **Pipeline** for dedicated, high-performance command processing
- Use **DynamicPipeline** for centralized routing and dynamic dispatch
- Both patterns can coexist in the same application
- Choose based on your specific architectural needs