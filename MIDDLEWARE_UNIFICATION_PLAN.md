# PipelineKit Middleware Unification Implementation Plan

## Overview

This document outlines the implementation plan to complete the middleware unification in PipelineKit and resolve all build failures and architectural issues identified in the codebase analysis.

## Architectural Decisions

### Adopted Architecture
- **Middleware Interface**: Context-based `(command, context, next)`
- **Protocol Constraints**: Allow both structs and classes (remove AnyObject requirement)
- **Context Keys**: Standardize on struct-based implementation
- **Naming Convention**: Use `StandardPipeline` as the primary implementation

## Implementation Phases

### Phase 1: Critical Build Fixes [BLOCKERS]

These must be completed first as they prevent compilation.

#### 1.1 Fix Duplicate Context Key Definitions

**Files to modify:**
- `Sources/PipelineKit/Middleware/Authorization/AuthorizationMiddleware.swift`

**Changes:**
```swift
// Remove these duplicate definitions (lines 40-46):
// public enum AuthenticatedUserKey: ContextKey { ... }
// public enum AuthorizationRolesKey: ContextKey { ... }

// Import the common keys instead:
// The keys are already defined in CommonContextKeys.swift
```

**Verification:**
- Build should no longer show "invalid redeclaration" errors

#### 1.2 Update Middleware Protocol

**File to modify:**
- `Sources/PipelineKit/Core/Protocols/Middleware.swift`

**Changes:**
```swift
/// Middleware provides cross-cutting functionality in the command pipeline.
public protocol Middleware: Sendable {  // Remove AnyObject requirement
    /// The priority of the middleware, which determines its execution order.
    var priority: ExecutionPriority { get }

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}

// Add extension for default priority
public extension Middleware {
    var priority: ExecutionPriority { .normal }
}
```

#### 1.3 Create Missing Protocol Definitions

**New file to create:**
- `Sources/PipelineKit/Core/Protocols/ContextAwareMiddleware.swift`

**Content:**
```swift
import Foundation

/// Protocol for middleware that requires context access
/// This is now just a marker protocol since all middleware use context
@available(*, deprecated, message: "All middleware now support context. Use Middleware protocol directly.")
public protocol ContextAwareMiddleware: Middleware {}
```

**New file to create:**
- `Sources/PipelineKit/Core/Protocols/PrioritizedMiddleware.swift`

**Content:**
```swift
import Foundation

/// Protocol for middleware with explicit priority
@available(*, deprecated, message: "Use Middleware protocol with priority property instead")
public protocol PrioritizedMiddleware: Middleware {}
```

### Phase 2: Complete Middleware Unification

#### 2.1 Update ResilientMiddleware

**File to modify:**
- `Sources/PipelineKit/Resilience/ResilientMiddleware.swift`

**Changes:**
```swift
public final class ResilientMiddleware: Middleware {
    public let priority: ExecutionPriority = .high
    private let retryPolicy: RetryPolicy
    private let circuitBreaker: CircuitBreaker?
    private let name: String
    
    // ... existing init ...
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,  // Changed from metadata
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Get metadata from context if needed
        let metadata = await context.commandMetadata
        
        // Check circuit breaker first
        if let breaker = circuitBreaker {
            guard await breaker.shouldAllow() else {
                throw ResilienceError.circuitOpen(name: name)
            }
        }
        
        do {
            let result = try await executeWithRetry(command, context: context, next: next)
            
            // Record success
            if let breaker = circuitBreaker {
                await breaker.recordSuccess()
            }
            
            return result
        } catch {
            // Record failure
            if let breaker = circuitBreaker {
                await breaker.recordFailure()
            }
            throw error
        }
    }
    
    private func executeWithRetry<T: Command>(
        _ command: T,
        context: CommandContext,  // Changed from metadata
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        var lastError: Error?
        let startTime = Date()
        let metadata = await context.commandMetadata
        
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                return try await next(command, context)
            } catch {
                lastError = error
                
                // Check if we should retry
                let recoveryContext = ErrorRecoveryContext(
                    command: command,
                    error: error,
                    attempt: attempt,
                    totalElapsedTime: Date().timeIntervalSince(startTime),
                    isFinalAttempt: attempt == retryPolicy.maxAttempts
                )
                
                guard !recoveryContext.isFinalAttempt && retryPolicy.shouldRetry(error) else {
                    throw error
                }
                
                // Wait before next attempt
                let delay = retryPolicy.delayStrategy.delay(for: attempt)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? ResilienceError.retryExhausted
    }
}
```

#### 2.2 Update All Middleware Classes

**Files to modify:**
- Convert struct middleware to final classes where they don't conform
- Add priority property where missing
- Ensure all use context-based signatures

#### 2.3 Fix Pipeline Naming Consistency

**Global find and replace:**
- Find: `DefaultPipeline`
- Replace with: `StandardPipeline`

**Exception:** The type alias in StandardPipeline.swift should be:
```swift
public typealias DefaultPipeline = StandardPipeline
```

### Phase 3: Implement Essential Middleware

#### 3.1 Implement TimeoutMiddleware

**New file to create:**
- `Sources/PipelineKit/Resilience/TimeoutMiddleware.swift`

**Content:**
```swift
import Foundation

/// Middleware that enforces time limits on command execution
public final class TimeoutMiddleware: Middleware {
    public let priority: ExecutionPriority = .high
    private let timeout: TimeInterval
    private let timeoutBudgetKey: TimeoutBudgetKey?
    
    public init(
        timeout: TimeInterval,
        cascading: Bool = false
    ) {
        self.timeout = timeout
        self.timeoutBudgetKey = cascading ? TimeoutBudgetKey() : nil
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let effectiveTimeout: TimeInterval
        
        if let budgetKey = timeoutBudgetKey,
           let budget = await context[budgetKey] {
            effectiveTimeout = budget.remaining
            guard effectiveTimeout > 0 else {
                throw ResilienceError.timeout(seconds: 0)
            }
        } else {
            effectiveTimeout = timeout
        }
        
        let startTime = Date()
        
        do {
            return try await withThrowingTaskGroup(of: T.Result.self) { group in
                group.addTask {
                    try await next(command, context)
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                    throw ResilienceError.timeout(seconds: effectiveTimeout)
                }
                
                let result = try await group.next()!
                group.cancelAll()
                
                // Update timeout budget if cascading
                if let budgetKey = timeoutBudgetKey {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if let budget = await context[budgetKey] {
                        let newBudget = budget.consume(elapsed)
                        await context.set(newBudget, for: budgetKey)
                    }
                }
                
                return result
            }
        } catch {
            throw error
        }
    }
}

private struct TimeoutBudgetKey: ContextKey {
    typealias Value = TimeoutBudget
}
```

#### 3.2 Implement TracingMiddleware

**New file to create:**
- `Sources/PipelineKit/Observability/TracingMiddleware.swift`

**Content:**
```swift
import Foundation

/// Middleware that provides distributed tracing capabilities
public final class TracingMiddleware: Middleware {
    public let priority: ExecutionPriority = .veryHigh
    private let serviceName: String
    private let tracer: any Tracer
    
    public init(serviceName: String, tracer: any Tracer = DefaultTracer()) {
        self.serviceName = serviceName
        self.tracer = tracer
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Get or create trace ID
        let traceId = await context[TraceIdKey.self] ?? UUID().uuidString
        await context.set(traceId, for: TraceIdKey.self)
        await context.set(serviceName, for: ServiceNameKey.self)
        
        // Create span
        let span = tracer.startSpan(
            name: String(describing: T.self),
            traceId: traceId,
            attributes: [
                "service.name": serviceName,
                "command.type": String(describing: T.self)
            ]
        )
        
        do {
            let result = try await next(command, context)
            span.setStatus(.ok)
            span.end()
            return result
        } catch {
            span.setStatus(.error(error))
            span.end()
            throw error
        }
    }
}

// Basic tracer protocol
public protocol Tracer: Sendable {
    func startSpan(name: String, traceId: String, attributes: [String: Any]) -> any Span
}

public protocol Span: Sendable {
    func setStatus(_ status: SpanStatus)
    func end()
}

public enum SpanStatus {
    case ok
    case error(Error)
}

// Default no-op implementation
struct DefaultTracer: Tracer {
    func startSpan(name: String, traceId: String, attributes: [String: Any]) -> any Span {
        NoOpSpan()
    }
}

struct NoOpSpan: Span {
    func setStatus(_ status: SpanStatus) {}
    func end() {}
}
```

### Phase 4: Fix Architectural Issues

#### 4.1 Fix Bulkhead Concurrency Issues

**File to modify:**
- `Sources/PipelineKit/Resilience/ResilientMiddleware.swift`

**Changes to Bulkhead actor:**
```swift
public actor Bulkhead {
    private let name: String
    private let maxConcurrency: Int
    private var activeCalls = 0
    private var waitQueue: [CheckedContinuation<Void, Error>] = []
    private let maxWaitingCalls: Int
    
    public init(
        name: String,
        maxConcurrency: Int,
        maxWaitingCalls: Int = 100
    ) {
        self.name = name
        self.maxConcurrency = maxConcurrency
        self.maxWaitingCalls = maxWaitingCalls
    }
    
    public func execute<T>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquireSlot()
        defer {
            Task { await self.releaseSlot() }
        }
        return try await operation()
    }
    
    private func acquireSlot() async throws {
        if activeCalls < maxConcurrency {
            activeCalls += 1
            return
        }
        
        guard waitQueue.count < maxWaitingCalls else {
            throw ResilienceError.bulkheadFull(name: name)
        }
        
        try await withCheckedThrowingContinuation { continuation in
            waitQueue.append(continuation)
        }
        
        activeCalls += 1
    }
    
    private func releaseSlot() {
        activeCalls -= 1
        
        if !waitQueue.isEmpty {
            let continuation = waitQueue.removeFirst()
            continuation.resume()
        }
    }
    
    public func getStats() -> BulkheadStats {
        BulkheadStats(
            name: name,
            activeCalls: activeCalls,
            waitingCalls: waitQueue.count,
            maxConcurrency: maxConcurrency
        )
    }
}
```

#### 4.2 Update Pipeline Templates

**File to modify:**
- `Sources/PipelineKit/Templates/PipelineTemplate.swift`

Update all template implementations to:
1. Use `StandardPipeline` instead of `DefaultPipeline`
2. Remove references to non-existent middleware
3. Add TODO comments for future middleware implementations

### Phase 5: Quality Assurance

#### 5.1 Add Comprehensive Tests

Create tests for:
- Context-based middleware execution
- Middleware priority ordering
- Timeout functionality
- Tracing integration
- Bulkhead concurrency handling

#### 5.2 Update Documentation

- Update README with new middleware examples
- Document the context-based architecture
- Add migration guide from metadata-based to context-based

#### 5.3 Update Examples

Update all example files to use:
- Correct middleware signatures
- StandardPipeline
- New context key patterns

## Validation Steps

### After Each Phase:
1. Run `swift build` to ensure no compilation errors
2. Run `swift test` to ensure no regressions
3. Review changes for consistency

### Final Validation:
1. All build errors resolved
2. All tests passing
3. Examples compile and run
4. Documentation accurate

## Risk Mitigation

### Potential Risks:
1. **Breaking Changes**: This is a major refactor that will break existing code
   - **Mitigation**: Clear migration guide and deprecation warnings

2. **Performance Impact**: Context-based middleware may have overhead
   - **Mitigation**: Benchmark before and after changes

3. **Incomplete Migration**: Some middleware might be missed
   - **Mitigation**: Comprehensive search for all middleware implementations

## Future Improvements (Not in Scope)

These items should be tracked as separate issues:
1. Implement CachingMiddleware
2. Implement DeduplicationMiddleware  
3. Implement IdempotencyMiddleware
4. Add OpenTelemetry integration for TracingMiddleware
5. Create CommandEncryptor implementation
6. Performance optimizations for context access

## Implementation Checklist

- [ ] Phase 1: Critical Build Fixes
  - [ ] Fix duplicate context keys
  - [ ] Update Middleware protocol
  - [ ] Create missing protocols
- [ ] Phase 2: Complete Middleware Unification
  - [ ] Update ResilientMiddleware
  - [ ] Update all middleware to use context
  - [ ] Fix pipeline naming
- [ ] Phase 3: Implement Essential Middleware
  - [ ] TimeoutMiddleware
  - [ ] TracingMiddleware
- [ ] Phase 4: Fix Architectural Issues
  - [ ] Fix Bulkhead concurrency
  - [ ] Update templates
- [ ] Phase 5: Quality Assurance
  - [ ] Add tests
  - [ ] Update documentation
  - [ ] Update examples

## Notes

- All middleware should follow the context-based pattern
- Use `StandardPipeline` as the primary implementation
- Maintain backward compatibility where possible with deprecation warnings
- Focus on getting a working build before optimization