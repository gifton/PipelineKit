# Choosing Between CommandBus and Pipeline

Learn when to use CommandBus for centralized routing versus Pipeline for direct execution.

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

### CommandBus: Centralized Routing

CommandBus provides a single entry point for multiple command types with dynamic routing:

```swift
// One bus handles multiple command types
let bus = CommandBus()
await bus.register(CreateUserCommand.self, handler: CreateUserHandler())
await bus.register(UpdateUserCommand.self, handler: UpdateUserHandler())
await bus.register(DeleteUserCommand.self, handler: DeleteUserHandler())

// Dynamic routing based on command type
let result = try await bus.send(command) // Any registered command
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

### Use CommandBus When:

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

### API Gateway (CommandBus)

```swift
// Centralized command routing for all services
class APIGateway {
    private let bus = CommandBus()
    
    init() async {
        // Register all service handlers
        await bus.register(PaymentCommand.self, handler: PaymentHandler())
        await bus.register(GetUserCommand.self, handler: UserHandler())
        await bus.register(OrderCommand.self, handler: OrderHandler())
        
        // Apply cross-cutting concerns to all
        await bus.addMiddleware(AuthenticationMiddleware())
        await bus.addMiddleware(LoggingMiddleware())
        await bus.addMiddleware(RateLimitingMiddleware())
    }
    
    // Single method handles all command types
    func handle<T: Command>(_ command: T) async throws -> T.Result {
        return try await bus.send(command)
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

// Expose via CommandBus for external API
class PublicAPI {
    private let bus = CommandBus()
    private let services = InternalServices()
    
    init() async {
        // Wrap pipelines in bus for unified access
        await bus.register(PaymentCommand.self) { command in
            try await services.paymentPipeline.execute(command)
        }
        await bus.register(GetUserCommand.self) { command in
            try await services.userPipeline.execute(command)
        }
    }
}
```

## Performance Considerations

### Execution Overhead
- **Pipeline**: ~0.006ms per command (baseline)
- **CommandBus**: ~0.008ms per command (+33% overhead)

### Memory Usage
- **Pipeline**: Handler + middleware array per pipeline
- **CommandBus**: Additional routing table + handler registry

### Scalability
- **Pipeline**: Linear with number of command types
- **CommandBus**: Constant regardless of command types

## Migration Path

If you're currently using CommandBusBuilder, migrate to direct CommandBus usage:

```swift
// Old approach (removed)
let builder = CommandBusBuilder()
await builder.with(CreateUserCommand.self, handler: CreateUserHandler())
let bus = await builder.build()

// New approach
let bus = CommandBus()
await bus.register(CreateUserCommand.self, handler: CreateUserHandler())
```

## Summary

- Use **Pipeline** for dedicated, high-performance command processing
- Use **CommandBus** for centralized routing and dynamic dispatch
- Both patterns can coexist in the same application
- Choose based on your specific architectural needs