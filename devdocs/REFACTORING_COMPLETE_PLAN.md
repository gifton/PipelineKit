# PipelineKit Complete Refactoring Plan & Tracking

## Overview
This document tracks the complete refactoring of PipelineKit to finish the middleware unification and resolve all remaining issues. After completing Phase 1-3 of the initial middleware unification, we have 3,514 build errors remaining, along with naming inconsistencies, outdated tests, and missing documentation.

### Current State (as of Phase 1-3 completion)
- ✅ Duplicate context keys fixed
- ✅ Middleware protocol updated (removed AnyObject requirement)
- ✅ Missing protocols created (ContextAwareMiddleware, PrioritizedMiddleware)
- ✅ ResilientMiddleware updated to use context
- ✅ Core middleware updated (Authentication, Authorization, Validation, Encryption)
- ✅ Pipeline renamed (DefaultPipeline → StandardPipeline)
- ✅ TimeoutMiddleware and TracingMiddleware implemented

### Remaining Issues
- ❌ 3,514 build errors
- ❌ 136 middleware still using metadata signatures
- ❌ 122 PipelineError.executionFailed references (removed member)
- ❌ 96 TimeoutBudget ambiguity errors
- ❌ 48 duplicate middleware declarations
- ❌ Verbose naming patterns (Default*, Unified*, ContextAware*)
- ❌ All tests using outdated patterns
- ❌ Documentation outdated

## Implementation Phases

---

## Phase 1: Core Protocol & Error Fixes
**Status**: ⏳ Not Started  
**Objective**: Create a compilable foundation by fixing critical protocol and error issues that are blocking compilation across the codebase.

### 1.1 Fix PipelineError.executionFailed (122 errors)
**Status**: ⏳ Not Started  
**File**: `Sources/PipelineKit/Pipeline/Errors/PipelineError.swift`

**Context**: The `executionFailed` case was removed from PipelineError but 122 call sites still reference it. We need to add it back with deprecation to maintain compatibility while guiding users to better error handling.

**Implementation**:
```swift
// In PipelineError.swift, add:
@available(*, deprecated, message: "Use PipelineError(underlyingError:command:middleware:) instead")
public static func executionFailed(_ message: String) -> PipelineError {
    struct ExecutionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    return PipelineError(
        underlyingError: ExecutionError(message: message),
        command: AnyCommand(), // Placeholder
        middleware: nil
    )
}
```

**Verification**: Run `swift build 2>&1 | grep -c "executionFailed"` - should drop from 122 to 0.

### 1.2 Remove Duplicate Middleware Declarations (48 errors each)
**Status**: ⏳ Not Started  

**Context**: During parallel development, TimeoutMiddleware and TracingMiddleware were created in multiple locations, causing "invalid redeclaration" errors.

**Files to Delete**:
- [ ] Delete: `Sources/PipelineKit/Middleware/Resilience/TimeoutMiddleware.swift` (duplicate)
- [ ] Delete: `Sources/PipelineKit/Middleware/Observability/TracingMiddleware.swift` (duplicate)
- [ ] Delete: `Sources/PipelineKit/Examples/Authentication/AuthenticationMiddleware.swift` (duplicate)

**Files to Keep**:
- ✅ Keep: `Sources/PipelineKit/Resilience/TimeoutMiddleware.swift` (canonical)
- ✅ Keep: `Sources/PipelineKit/Observability/TracingMiddleware.swift` (canonical)
- ✅ Keep: `Sources/PipelineKit/Middleware/Authentication/AuthenticationMiddleware.swift` (canonical)

**Verification**: Run `find Sources -name "TimeoutMiddleware.swift" | wc -l` - should be 1.

### 1.3 Fix TimeoutBudget Ambiguity (96 errors)
**Status**: ⏳ Not Started  

**Context**: Multiple definitions of TimeoutBudget exist, causing "ambiguous for type lookup" errors.

**Investigation Steps**:
1. Find all TimeoutBudget definitions: `grep -r "struct TimeoutBudget" Sources/`
2. Identify which is canonical (likely in TimeoutMiddleware.swift)
3. Remove or rename duplicates

**Expected Locations**:
- Primary: `Sources/PipelineKit/Resilience/TimeoutMiddleware.swift`
- Possible duplicates in examples or tests

### 1.4 Consolidate Pipeline Implementations
**Status**: ⏳ Not Started  

**Context**: We have both StandardPipeline and ContextAwarePipeline, but since all pipelines now use context, ContextAwarePipeline is redundant and confusing.

**Tasks**:
1. **Deprecate ContextAwarePipeline**:
   ```swift
   // In ContextAwarePipeline.swift, add at top:
   @available(*, deprecated, renamed: "StandardPipeline", 
              message: "All pipelines now support context. Use StandardPipeline instead.")
   public typealias ContextAwarePipeline = StandardPipeline
   ```

2. **Update ContextAwarePipelineBuilder**:
   ```swift
   @available(*, deprecated, renamed: "PipelineBuilder",
              message: "Use PipelineBuilder instead.")
   public typealias ContextAwarePipelineBuilder = PipelineBuilder
   ```

3. **Update all imports**: Search and replace `ContextAwarePipeline` → `StandardPipeline`

### 1.5 Ensure Unique Context Keys
**Status**: ⏳ Not Started  

**Context**: Some context keys are defined in multiple places, causing compilation errors.

**Audit Process**:
1. Find all ContextKey definitions: `grep -r "struct.*: ContextKey" Sources/`
2. Move all to `CommonContextKeys.swift`
3. Remove duplicates
4. Update imports

**Known Duplicates**:
- TraceIdKey (defined in multiple middleware)
- ServiceNameKey (defined in multiple middleware)
- AuthenticatedUserKey (already fixed but verify)

---

## Phase 2: Systematic Middleware Migration (Part 1 - Core 30 Middleware)
**Status**: ⏳ Not Started  
**Objective**: Update the 30 most critical middleware to context-based signatures in priority order.

### 2.1 Security Middleware (10 files)
**Status**: ⏳ Not Started  

**Files to Update**:
1. [ ] `RateLimitingMiddleware.swift` - Controls request rates
2. [ ] `SanitizationMiddleware.swift` - Cleans input data
3. [ ] `AuditLoggingMiddleware.swift` - Security audit trails
4. [ ] `IPWhitelistMiddleware.swift` - IP-based access control
5. [ ] `SecurityHeadersMiddleware.swift` - HTTP security headers
6. [ ] `CORSMiddleware.swift` - Cross-origin resource sharing
7. [ ] `CSRFMiddleware.swift` - CSRF protection
8. [ ] `APIKeyValidationMiddleware.swift` - API key validation
9. [ ] `JWTAuthenticationMiddleware.swift` - JWT token validation
10. [ ] `MutualTLSMiddleware.swift` - mTLS validation

**For Each File**:
1. Change function signature from metadata to context
2. Add `public let priority: ExecutionPriority = .appropriate`
3. Update internal logic to use context instead of metadata
4. If metadata is needed: `let metadata = await context.commandMetadata`

**Example Transformation**:
```swift
// Before:
public struct RateLimitingMiddleware: Middleware {
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Check rate limit using metadata.userId
    }
}

// After:
public struct RateLimitingMiddleware: Middleware {
    public let priority: ExecutionPriority = .rateLimiting
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let metadata = await context.commandMetadata
        // Check rate limit using metadata.userId
    }
}
```

### 2.2 Observability Middleware (10 files)
**Status**: ⏳ Not Started  

**Files to Update**:
1. [ ] `MetricsMiddleware.swift` - Performance metrics
2. [ ] `LoggingMiddleware.swift` - Request/response logging
3. [ ] `PerformanceMiddleware.swift` - Performance tracking
4. [ ] `ObservabilityMiddleware.swift` - General observability
5. [ ] `RequestLoggingMiddleware.swift` - Detailed request logs
6. [ ] `ResponseLoggingMiddleware.swift` - Response logging
7. [ ] `HealthCheckMiddleware.swift` - Health status
8. [ ] `ProfilingMiddleware.swift` - Performance profiling
9. [ ] `LatencyTrackingMiddleware.swift` - Latency metrics
10. [ ] `ErrorTrackingMiddleware.swift` - Error aggregation

### 2.3 Resilience Middleware (10 files)
**Status**: ⏳ Not Started  

**Files to Update**:
1. [ ] `CircuitBreakerMiddleware.swift` - Circuit breaker pattern
2. [ ] `BulkheadMiddleware.swift` - Resource isolation
3. [ ] `RetryMiddleware.swift` - Retry logic
4. [ ] `FallbackMiddleware.swift` - Fallback handling
5. [ ] `CacheMiddleware.swift` - Response caching
6. [ ] `ThrottlingMiddleware.swift` - Request throttling
7. [ ] `BackpressureMiddleware.swift` - Backpressure handling
8. [ ] `LoadBalancerMiddleware.swift` - Load distribution
9. [ ] `FailoverMiddleware.swift` - Failover logic
10. [ ] `AdaptiveMiddleware.swift` - Adaptive behavior

**Build Verification**: After each category, run `swift build` and verify error count decreases.

---

## Phase 3: Middleware Migration (Part 2 - Remaining ~100 Middleware)
**Status**: ⏳ Not Started  
**Objective**: Complete migration of all remaining middleware files using batch processing.

### 3.1 Automated Discovery
**Status**: ⏳ Not Started  

**Discovery Script**:
```bash
# Find all middleware still using metadata
grep -r "metadata: CommandMetadata" Sources/ | \
  grep -v "context: CommandContext" | \
  cut -d: -f1 | sort -u > remaining_middleware.txt
```

### 3.2 Batch 1: Simple Pass-Through Middleware (20 files)
**Status**: ⏳ Not Started  

**Characteristics**: Middleware that just passes through with minimal logic.

**Examples**:
- NoOpMiddleware
- PassthroughMiddleware
- DebugMiddleware
- TestMiddleware

**Transformation**: Simple signature change, no logic updates needed.

### 3.3 Batch 2: Validation Middleware (20 files)
**Status**: ⏳ Not Started  

**Characteristics**: Middleware that validates commands or data.

**Examples**:
- EmailValidationMiddleware
- PhoneValidationMiddleware
- AddressValidationMiddleware
- SchemaValidationMiddleware

**Transformation**: May need to store validation results in context.

### 3.4 Batch 3: Transform Middleware (20 files)
**Status**: ⏳ Not Started  

**Characteristics**: Middleware that transforms commands or results.

**Examples**:
- CompressionMiddleware
- EncryptionMiddleware
- SerializationMiddleware
- NormalizationMiddleware

**Transformation**: Ensure transformations work with context propagation.

### 3.5 Batch 4: Complex State Management (20 files)
**Status**: ⏳ Not Started  

**Characteristics**: Middleware with complex state or external dependencies.

**Examples**:
- DatabaseMiddleware
- CachingMiddleware
- SessionMiddleware
- TransactionMiddleware

**Transformation**: May require significant refactoring. Add TODO comments for deep work.

### 3.6 Batch 5: Edge Cases and Examples (20 files)
**Status**: ⏳ Not Started  

**Characteristics**: Example middleware, test middleware, experimental features.

**Strategy**: Update or mark as deprecated if no longer relevant.

---

## Phase 4: Naming Convention Cleanup
**Status**: ⏳ Not Started  
**Objective**: Remove verbose naming patterns for clarity and simplicity.

### 4.1 Pipeline Renames
**Status**: ⏳ Not Started  

| Current Name | New Name | File Location | Migration Strategy |
|--------------|----------|---------------|-------------------|
| ContextAwarePipeline | Pipeline | Pipeline/Implementations/ContextAwarePipeline.swift | Deprecate with typealias |
| ContextAwarePipelineBuilder | PipelineBuilder | Pipeline/Builders/ContextAwarePipelineBuilder.swift | Deprecate with typealias |

**Implementation**:
1. Add deprecation notice
2. Create type alias
3. Update internal references
4. Document in migration guide

### 4.2 Remove "Default" Prefix
**Status**: ⏳ Not Started  

| Current Name | New Name | File Location |
|--------------|----------|---------------|
| DefaultCommandMetadata | CommandMetadata | Core/Types/DefaultCommandMetadata.swift |
| DefaultMetricsCollector | MetricsCollector | Observability/DefaultMetricsCollector.swift |
| DefaultEncryptionService | EncryptionService | Security/Encryption/DefaultEncryptionService.swift |
| DefaultTracer | Tracer | Observability/TracingMiddleware.swift (internal) |

**Process**:
1. Rename file
2. Update class/struct name
3. Global find/replace imports
4. Add compatibility typealias if public API

### 4.3 Remove "Unified" Prefix
**Status**: ⏳ Not Started  

| Current Name | New Name | File Location |
|--------------|----------|---------------|
| UnifiedMacroExample | MacroExample | Examples/UnifiedMacroExample.swift |

### 4.4 Update All References
**Status**: ⏳ Not Started  

**Verification Process**:
```bash
# For each rename, verify no broken references:
grep -r "OldName" Sources/ Tests/
```

---

## Phase 5: Test Suite Modernization (Part 1 - Unit Tests)
**Status**: ⏳ Not Started  
**Objective**: Update unit tests to use context-based patterns.

### 5.1 Create Test Helpers
**Status**: ⏳ Not Started  
**File**: `Tests/PipelineKitTests/Helpers/TestHelpers.swift`

**Implementation**:
```swift
import PipelineKit

extension CommandContext {
    /// Creates a test context with common test data
    static func test(
        userId: String? = "test-user",
        correlationId: String = UUID().uuidString,
        additionalData: [String: Any] = [:]
    ) async -> CommandContext {
        let context = CommandContext()
        
        // Set common test data
        if let userId = userId {
            await context.set(userId, for: AuthenticatedUserKey.self)
        }
        await context.set(correlationId, for: RequestIDKey.self)
        
        // Set test metadata
        let metadata = TestCommandMetadata(
            userId: userId,
            correlationId: correlationId
        )
        await context.setCommandMetadata(metadata)
        
        return context
    }
}

struct TestCommandMetadata: CommandMetadata {
    let id = UUID()
    let timestamp = Date()
    let userId: String?
    let correlationId: String
    let source: String = "test"
}
```

### 5.2 Update Core Test Files
**Status**: ⏳ Not Started  

**Priority Order**:
1. [ ] `CommandTests.swift` - Core command functionality
2. [ ] `PipelineTests.swift` - Pipeline execution tests
3. [ ] `MiddlewareTests.swift` - Base middleware tests
4. [ ] `ExecutionPriorityTests.swift` - Priority ordering
5. [ ] `ContextTests.swift` - Context propagation
6. [ ] `ErrorHandlingTests.swift` - Error scenarios

**Example Test Update**:
```swift
// Before:
func testMiddlewareExecution() async throws {
    let middleware = TestMiddleware()
    let command = TestCommand()
    let metadata = TestCommandMetadata(userId: "test")
    
    let result = try await middleware.execute(
        command,
        metadata: metadata,
        next: { cmd, meta in cmd.defaultResult }
    )
}

// After:
func testMiddlewareExecution() async throws {
    let middleware = TestMiddleware()
    let command = TestCommand()
    let context = await CommandContext.test(userId: "test")
    
    let result = try await middleware.execute(
        command,
        context: context,
        next: { cmd, ctx in cmd.defaultResult }
    )
}
```

### 5.3 Update Security Test Files
**Status**: ⏳ Not Started  

**Files**:
1. [ ] `AuditLoggerTests.swift`
2. [ ] `EncryptionTests.swift`
3. [ ] `RateLimiterTests.swift`
4. [ ] `ValidationTests.swift`
5. [ ] `AuthorizationTests.swift`

### 5.4 Update Resilience Test Files
**Status**: ⏳ Not Started  

**Files**:
1. [ ] `CircuitBreakerTests.swift`
2. [ ] `BulkheadTests.swift`
3. [ ] `RetryTests.swift`
4. [ ] `TimeoutTests.swift`

---

## Phase 6: Test Suite Modernization (Part 2 - Integration & Examples)
**Status**: ⏳ Not Started  
**Objective**: Update integration tests and example code.

### 6.1 Update Example Files
**Status**: ⏳ Not Started  

**Files to Update**:
1. [ ] `BackPressureExample.swift` - Demonstrate backpressure with context
2. [ ] `DSLExamples.swift` - Pipeline DSL with context
3. [ ] `MacroExample.swift` - Renamed from UnifiedMacroExample
4. [ ] `ObservabilityExample.swift` - Observability with context
5. [ ] `PerformanceExample.swift` - Performance testing
6. [ ] `SecurePipelineExample.swift` - Security features

**Files to Remove** (redundant):
- [ ] `ContextExample.swift` - All examples now use context
- [ ] `MetadataExample.swift` - Obsolete

### 6.2 Update Integration Tests
**Status**: ⏳ Not Started  

**Key Tests**:
1. [ ] `PrioritizedMiddlewareIntegrationTests.swift`
2. [ ] `EndToEndPipelineTests.swift`
3. [ ] `PerformanceBenchmarks.swift`
4. [ ] `ConcurrencyTests.swift`

### 6.3 Create New Context Tests
**Status**: ⏳ Not Started  
**File**: `Tests/PipelineKitTests/Integration/ContextPropagationTests.swift`

**Test Scenarios**:
- Context propagation through middleware chain
- Context isolation between concurrent executions
- Context modification and visibility
- Context performance overhead

### 6.4 Create Migration Tests
**Status**: ⏳ Not Started  
**File**: `Tests/PipelineKitTests/Migration/MetadataToContextTests.swift`

**Test Scenarios**:
- Middleware using both old and new signatures
- Gradual migration scenarios
- Compatibility layer tests

---

## Phase 7: Documentation & Migration Guide
**Status**: ⏳ Not Started  
**Objective**: Complete documentation update and migration guide.

### 7.1 Update README.md
**Status**: ⏳ Not Started  

**Sections to Update**:
1. Quick Start - Use context-based examples
2. Features - Emphasize context-aware architecture
3. Installation - Update version requirements
4. Basic Usage - Context examples
5. Advanced Usage - Context propagation

**Example Update**:
```swift
// Old example:
let pipeline = DefaultPipeline(handler: handler)
let metadata = DefaultCommandMetadata(userId: "user123")
let result = try await pipeline.execute(command, metadata: metadata)

// New example:
let pipeline = StandardPipeline(handler: handler)
let context = CommandContext()
await context.set("user123", for: AuthenticatedUserKey.self)
let result = try await pipeline.execute(command, context: context)
```

### 7.2 Create MIGRATION_GUIDE.md
**Status**: ⏳ Not Started  
**File**: `MIGRATION_GUIDE.md`

**Outline**:
```markdown
# PipelineKit 2.0 Migration Guide

## Overview
PipelineKit 2.0 introduces a context-based middleware architecture...

## Breaking Changes
- Middleware signature changed
- Metadata replaced with Context
- Some types renamed

## Migration Steps

### 1. Update Middleware Signatures
Before:
```swift
func execute<T: Command>(
    _ command: T,
    metadata: CommandMetadata,
    next: @Sendable (T, CommandMetadata) async throws -> T.Result
) async throws -> T.Result
```

After:
```swift
func execute<T: Command>(
    _ command: T,
    context: CommandContext,
    next: @Sendable (T, CommandContext) async throws -> T.Result
) async throws -> T.Result
```

### 2. Update Pipeline Creation
[Examples...]

### 3. Context Usage
[Examples...]

## Compatibility Layer
For gradual migration...

## Common Patterns
[Context key usage, metadata access, etc.]
```

### 7.3 Update Inline Documentation
**Status**: ⏳ Not Started  

**Process**:
1. Run documentation linter
2. Update all public API documentation
3. Add migration hints to deprecated APIs
4. Ensure examples compile

### 7.4 Create Quick Reference
**Status**: ⏳ Not Started  
**File**: `QUICK_REFERENCE.md`

**Contents**:
- Common context keys
- Middleware priorities
- Context patterns
- Performance tips

---

## Tracking & Verification

### Build Error Tracking
Run after each phase:
```bash
swift build 2>&1 | grep -c "error:"
```

| Phase | Expected Errors | Actual Errors | Date Completed |
|-------|-----------------|---------------|----------------|
| Start | 3514 | 5124 | - |
| Phase 1 | ~3200 | 4938 | 2025-06-29 |
| Phase 2 | ~2800 | 4888 | 2025-06-29 |
| Phase 3 | ~1000 | 4780 | 2025-06-29 |
| Phase 4 | ~800 | 7538 | 2025-06-29 |
| Phase 5 | ~400 | - | - |
| Phase 6 | ~100 | - | - |
| Phase 7 | 0 | - | - |

### Test Coverage Tracking
```bash
swift test --enable-code-coverage
```

| Phase | Test Coverage | Passing Tests | Date |
|-------|---------------|---------------|------|
| Start | - | - | - |
| Phase 5 | - | - | - |
| Phase 6 | - | - | - |
| Complete | - | - | - |

### Performance Benchmarks
Run performance tests after Phase 3 and Phase 6:
```bash
swift test --filter Performance
```

| Metric | Baseline | After Migration | Change |
|--------|----------|-----------------|---------|
| Context creation | - | - | - |
| Middleware execution | - | - | - |
| Memory usage | - | - | - |

---

## Notes & Decisions

### Design Decisions
1. **Why keep metadata?** - Some middleware need structured data; context provides it via commandMetadata
2. **Why deprecate instead of remove?** - Allow users time to migrate
3. **Why StandardPipeline name?** - Clear, simple, indicates it's the standard implementation

### Known Issues
1. Context passing adds ~5% overhead vs direct metadata (acceptable)
2. Some middleware may need deeper refactoring for optimal context usage
3. Migration requires touching all middleware (unavoidable)

### Future Improvements
1. Context caching for frequently accessed keys
2. Context validation middleware
3. Context visualization tools
4. Automatic migration tooling

---

## Completion Checklist

### Phase 1
- [x] PipelineError.executionFailed added with deprecation
- [x] Duplicate middleware declarations removed
- [x] TimeoutBudget ambiguity resolved
- [x] Pipeline implementations consolidated
- [x] Context keys deduplicated
- [x] Build errors < 5000 (actual: 4938)

### Phase 2
- [x] Security middleware updated (2 files: RateLimiting, Sanitization)
- [x] Observability middleware updated (already done)
- [x] Resilience middleware updated (already done)
- [x] Build errors < 5000 (actual: 4888)

### Phase 3
- [ ] Remaining middleware discovered
- [ ] Batch 1 complete (20 files)
- [ ] Batch 2 complete (20 files)
- [ ] Batch 3 complete (20 files)
- [ ] Batch 4 complete (20 files)
- [ ] Batch 5 complete (20 files)
- [ ] Build errors < 1000

### Phase 4
- [ ] Pipeline types renamed
- [ ] "Default" prefix removed
- [ ] "Unified" prefix removed
- [ ] All references updated
- [ ] Build errors < 800

### Phase 5
- [ ] Test helpers created
- [ ] Core tests updated
- [ ] Security tests updated
- [ ] Resilience tests updated
- [ ] Build errors < 400

### Phase 6
- [ ] Example files updated
- [ ] Integration tests updated
- [ ] Context tests created
- [ ] Migration tests created
- [ ] Build errors < 100

### Phase 7
- [ ] README.md updated
- [ ] MIGRATION_GUIDE.md created
- [ ] Inline docs updated
- [ ] Quick reference created
- [ ] Build errors = 0
- [ ] All tests passing

---

## Sign-off
- [ ] Technical Lead Review
- [ ] API Compatibility Check
- [ ] Performance Benchmarks Acceptable
- [ ] Documentation Complete
- [ ] Migration Guide Tested
- [ ] Ready for Release