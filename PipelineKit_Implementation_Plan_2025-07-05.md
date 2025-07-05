# PipelineKit v1.0 Implementation Plan
**Date: 2025-07-05**

## Executive Summary

This implementation plan outlines the transformation of PipelineKit from an over-engineered prototype to a streamlined, production-ready command-pipeline framework. Since this is pre-release, we can make aggressive changes without migration concerns.

## Overview

```
Current State                        Target State
-------------                        ------------
- Build failures                     - Clean, modular build
- 51+ middleware priorities          - 5-7 essential priorities  
- 3 context implementations          - 1 unified context
- Multiple pipeline types            - 2 core types
- Unsafe concurrency                 - Modern Swift actors
- Monolithic architecture            - Modular design
```

## Implementation Phases

### Phase 1: Aggressive Cleanup
**Priority: CRITICAL**

#### 1.1 Fix Build Issues
- [ ] Delete duplicate `/Sources/PipelineKit/Optimized/` directory entirely
- [ ] Keep only `/Sources/PipelineKit/Core/Types/` implementations
- [ ] Update all imports
- [ ] Verify clean build on all platforms

#### 1.2 Remove All Deprecated Code
- [ ] Delete `LockFreeQueue` and `SafeLockFreeQueue` - replace with actors
- [ ] Delete `BatchProcessor` and `SafeBatchProcessor` - rewrite from scratch
- [ ] Remove all `@available(*, deprecated)` code
- [ ] Delete unused files and experiments

#### 1.3 Establish Testing Baseline
- [ ] Keep only tests for features we're keeping
- [ ] Delete tests for removed code
- [ ] Set up performance benchmarks for new implementation

**Success Criteria**: Clean build, no legacy code, focused test suite

---

### Phase 2: Radical API Simplification
**Priority: HIGH**

#### 2.1 Replace ExecutionPriority
Delete the 51+ priority enum entirely and replace with:
```swift
public enum ExecutionPriority: Int {
    case authentication = 100    
    case validation = 200        
    case preProcessing = 300     
    case processing = 400        
    case postProcessing = 500    
    case custom(Int)             
}
```

#### 2.2 Delete MiddlewareRegistry
- [ ] Remove entire MiddlewareRegistry system
- [ ] Users explicitly create and configure their middleware
- [ ] No "magic" default implementations

#### 2.3 Streamline Middleware
Keep only essential middleware:
- [ ] AuthenticationMiddleware
- [ ] ValidationMiddleware  
- [ ] RateLimitingMiddleware
- [ ] MetricsMiddleware
- [ ] CachingMiddleware
- Delete all others (users can create custom ones)

---

### Phase 3: Single Context Implementation
**Priority: HIGH**

#### 3.1 Delete All Optimized Variants
- [ ] Delete entire `/Sources/PipelineKit/Optimized/` directory
- [ ] Delete `/Sources/PipelineKit/Core/Types/OptimizedCommandContext.swift`
- [ ] Keep only the actor-based `CommandContext`

#### 3.2 Simplify Context API
```swift
public actor CommandContext {
    // Direct property access for common keys
    public var requestId: String = UUID().uuidString
    public var userId: String?
    public var startTime: Date = Date()
    
    // Generic storage for custom keys
    private var storage: [String: Any] = [:]
    
    public subscript(key: String) -> Any? {
        get { storage[key] }
        set { storage[key] = newValue }
    }
}
```

---

### Phase 4: Two Pipeline Types Only
**Priority: HIGH**

#### 4.1 Delete All Pipeline Variants
- [ ] Delete OptimizedStandardPipeline
- [ ] Delete PriorityPipeline  
- [ ] Delete PersistentPipeline
- [ ] Delete all experimental pipelines

#### 4.2 Keep Only Two Types
```swift
// Basic pipeline for single commands
public actor Pipeline {
    private let middleware: [Middleware]
    private let handler: any CommandHandler
    
    public func execute(_ command: any Command) async throws -> Any
}

// Concurrent pipeline for batch operations
public actor ConcurrentPipeline {
    private let pipeline: Pipeline
    private let maxConcurrency: Int
    
    public func execute(_ commands: [any Command]) async throws -> [Result<Any, Error>]
}
```

#### 4.3 Simple Builder Pattern
```swift
let pipeline = Pipeline {
    AuthenticationMiddleware()
    ValidationMiddleware()
    // Custom middleware here
}
.handler(MyCommandHandler())
.maxConcurrency(10)
```

---

### Phase 5: Modern Swift Concurrency
**Priority: CRITICAL**

#### 5.1 Delete All Unsafe Code
- [ ] Delete entire `/Sources/PipelineKit/LockFree/` directory
- [ ] Delete all Atomics-based implementations
- [ ] Remove all unsafe pointer usage

#### 5.2 Actor-Based Everything
```swift
// Replace complex atomics with simple actors
public actor MetricsCollector {
    private var metrics = Metrics()
    
    func record(command: String, duration: TimeInterval, success: Bool) {
        metrics.totalCommands += 1
        metrics.totalDuration += duration
        if !success { metrics.failures += 1 }
    }
}
```

#### 5.3 Use Structured Concurrency
- [ ] Replace continuations with async/await
- [ ] Use TaskGroup for parallel execution
- [ ] Implement proper cancellation

---

### Phase 6: Clean Module Structure
**Priority: MEDIUM**

#### 6.1 Reorganize Files
```
PipelineKit/
├── Sources/
│   ├── PipelineKit/           # Core only
│   │   ├── Pipeline.swift
│   │   ├── Command.swift
│   │   ├── Middleware.swift
│   │   └── Context.swift
│   │
│   ├── PipelineKitSecurity/   # Separate target
│   │   ├── Authentication.swift
│   │   └── RateLimiting.swift
│   │
│   └── PipelineKitExtras/     # Separate target
│       ├── Caching.swift
│       └── Metrics.swift
```

#### 6.2 Clean Package.swift
```swift
let package = Package(
    name: "PipelineKit",
    products: [
        .library(name: "PipelineKit", targets: ["PipelineKit"]),
        .library(name: "PipelineKitSecurity", targets: ["PipelineKitSecurity"]),
        .library(name: "PipelineKitExtras", targets: ["PipelineKitExtras"])
    ],
    dependencies: [
        // Remove swift-atomics dependency entirely
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "510.0.3")
    ]
)
```

---

### Phase 7: Documentation & Examples
**Priority: HIGH**

#### 7.1 Clean Documentation
- [ ] Write fresh README focused on the clean API
- [ ] Create 3-5 focused examples
- [ ] Generate DocC documentation
- [ ] No migration guides needed!

#### 7.2 Example Projects
```
Examples/
├── BasicPipeline/      # Minimal usage
├── SecurePipeline/     # With auth & rate limiting
└── HighPerformance/    # Concurrent processing
```

#### 7.3 Initial Release
- [ ] Version as 1.0.0 (first release)
- [ ] Clean changelog (no legacy mentions)
- [ ] Fresh start with best practices

---

## Implementation Guidelines

### Aggressive Simplification
- Delete first, ask questions later
- If in doubt, remove it
- Start minimal, add only what's proven necessary
- No premature optimization

### Clean Code Principles
- Modern Swift only (5.10+)
- Actors over manual synchronization
- Protocol-oriented but not overly generic
- Clear > Clever

### No Legacy Burden
- No deprecation warnings
- No migration support
- No backwards compatibility
- Clean, modern API from day one

## Success Metrics

1. **Code Reduction**
   - [ ] 50%+ fewer lines of code
   - [ ] 80%+ fewer files
   - [ ] Zero deprecated code

2. **API Simplicity**
   - [ ] 2 pipeline types (down from 6+)
   - [ ] 5 middleware priorities (down from 51+)
   - [ ] 1 context implementation (down from 3)

3. **Modern Swift**
   - [ ] 100% actor-based concurrency
   - [ ] Zero unsafe code
   - [ ] No external dependencies (except swift-syntax for macros)

4. **Developer Experience**
   - [ ] Can understand API in 5 minutes
   - [ ] "Hello World" in under 10 lines
   - [ ] No surprising behavior

## Benefits of Pre-Release Refactoring

1. **No Migration Burden**
   - Change anything without constraints
   - Delete without deprecation
   - Rename without aliases

2. **Clean Architecture**
   - Start with best practices
   - No technical debt from day one
   - Modern Swift throughout

3. **Focused Scope**
   - Ship only proven features
   - No experimental code
   - Clear use cases

## Next Steps

1. Create fresh branch (not v2.0, just main)
2. Start with Phase 1 aggressive cleanup
3. Move fast, delete aggressively
4. Test the clean implementation
5. Ship 1.0.0 when ready

---

**Note**: This plan embraces the freedom of pre-release development. We can make the best possible API without legacy constraints.