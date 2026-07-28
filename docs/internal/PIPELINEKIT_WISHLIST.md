# PipelineKit Enhancement Wishlist

Enhancements that would benefit GournalCore's deep integration, organized by priority and complexity.

---

## Tier 1: High Impact, Likely Essential

### 1.1 Typed/Scoped Middleware

**Problem:** All middleware receives all commands via generic `execute<T: Command>`. Middleware must runtime-check command types or apply universally.

**Current Workaround:**
```swift
func execute<T: Command>(_ command: T, ...) async throws -> T.Result {
    guard command is CreateEntryCommand || command is UpdateEntryCommand else {
        return try await next(command, context) // Skip
    }
    // Actual logic
}
```

**Desired:**
```swift
// Option A: Protocol constraint
protocol TypedMiddleware {
    associatedtype CommandType: Command
    func execute(_ command: CommandType, ...) async throws -> CommandType.Result
}

// Option B: Registration-time scoping
pipeline.addMiddleware(EncryptionMiddleware(), appliesTo: [
    CreateEntryCommand.self,
    UpdateEntryCommand.self
])

// Option C: Command marker protocol
protocol RequiresEncryption: Command {}
struct CreateEntryCommand: Command, RequiresEncryption { ... }
// EncryptionMiddleware only activates for RequiresEncryption conformers
```

**GournalCore Need:** Encryption, embedding generation, and IR processing should only apply to entry mutation commands, not search or maintenance commands.

---

### 1.2 Deferred/Background Command Execution

**Problem:** All commands execute synchronously. No built-in support for fire-and-forget with retry.

**Current Workaround:** Manual Task spawning outside pipeline, losing middleware benefits.

**Desired:**
```swift
protocol DeferrableCommand: Command {
    static var canDefer: Bool { get }
    static var maxRetryAttempts: Int { get }
    static var retryBackoff: DelayStrategy { get }
}

// Pipeline API
let handle = await pipeline.defer(GenerateEmbeddingCommand(entryId: id))
// handle.status, handle.cancel(), handle.await()

// Or fire-and-forget
await pipeline.fireAndForget(GenerateIRCommand(entryId: id))
```

**GournalCore Need:** Embedding generation and IR processing should run in background after entry creation returns. Failures should retry automatically without blocking the user.

---

### 1.3 Command Composition / Chaining

**Problem:** Multi-step operations require manual orchestration. No declarative way to express "do A, then B, then C" with proper error handling.

**Current Workaround:** Handler calls other handlers or pipeline recursively.

**Desired:**
```swift
// Option A: Declarative chain
let createEntryFlow = CommandChain(CreateEntryCommand.self)
    .then { entry in GenerateEmbeddingCommand(entryId: entry.id) }
    .then { _ in UpdateSearchIndexCommand() }
    .onError { error, context in
        // Compensation logic
    }

// Option B: Composite command
struct CreateEntryWithProcessingCommand: CompositeCommand {
    let request: CreateEntryRequest

    var steps: [any Command] {
        [
            CreateEntryCommand(request: request),
            GenerateEmbeddingCommand.deferred(entryId: .placeholder),
            GenerateIRCommand.deferred(entryId: .placeholder)
        ]
    }
}

// Option C: Middleware-based chaining (simpler)
// PostProcessingMiddleware triggers follow-up commands based on result
```

**GournalCore Need:** Entry creation involves: persist → generate embedding → update index → generate IR. These have different failure semantics (persist must succeed, others can fail gracefully).

---

### 1.4 Progress/Streaming Results

**Problem:** Commands return a single final result. No way to report progress during long operations.

**Current Workaround:** Callback parameters, breaking the command pattern.

**Desired:**
```swift
protocol ProgressiveCommand: Command {
    associatedtype Progress: Sendable
    // Result is the final result
}

// Handler signature
func handle(_ command: BackfillCommand) -> AsyncThrowingStream<BackfillProgress, Error>

// Or bidirectional
protocol StreamingCommand: Command {
    associatedtype Progress: Sendable
    associatedtype FinalResult: Sendable
    typealias Result = StreamingResult<Progress, FinalResult>
}

struct StreamingResult<P, R> {
    let progress: AsyncStream<P>
    let finalResult: () async throws -> R
}
```

**GournalCore Need:** Backfill operations process hundreds of entries. UI needs progress updates. IR generation has phases (extraction, analysis, embedding).

---

## Tier 2: High Value, Moderate Complexity

### 2.1 Conditional Middleware Activation

**Problem:** Middleware executes unconditionally. Feature flags require internal checks.

**Current Workaround:**
```swift
func execute<T: Command>(...) async throws -> T.Result {
    guard context.featureFlags.encryptionEnabled else {
        return try await next(command, context)
    }
    // Actual encryption
}
```

**Desired:**
```swift
// Option A: Protocol method
protocol ConditionalMiddleware: Middleware {
    func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool
}

// Option B: Registration-time predicate
pipeline.addMiddleware(
    EncryptionMiddleware(),
    when: { _, context in context[\.featureFlags].encryptionEnabled }
)

// Option C: Context-based disable
context.disableMiddleware(EncryptionMiddleware.self)
```

**GournalCore Need:** Encryption is feature-flagged. IR generation only runs if AI is available. Search caching can be disabled for debugging.

---

### 2.2 Transaction/Unit of Work Middleware

**Problem:** No coordination for transactional operations across handler execution.

**Current Workaround:** Handler manages its own transaction, or context carries transaction state manually.

**Desired:**
```swift
protocol Transactional: Command {}

// TransactionMiddleware automatically wraps Transactional commands
struct TransactionMiddleware<T: TransactionProvider>: Middleware {
    let provider: T

    func execute<C: Command>(...) async throws -> C.Result {
        guard C.self is Transactional.Type else {
            return try await next(command, context)
        }

        let tx = try await provider.begin()
        context[\.transaction] = tx

        do {
            let result = try await next(command, context)
            try await provider.commit(tx)
            return result
        } catch {
            try await provider.rollback(tx)
            throw error
        }
    }
}

// SwiftData-specific (could be in PipelineKitSwiftData module)
extension ModelContext: TransactionProvider { ... }
```

**GournalCore Need:** Entry creation with multiple fragments should be atomic. SwiftData ModelContext needs lifecycle management.

---

### 2.3 Result Transformation at Pipeline Boundary

**Problem:** Command Result type is fixed. Can't transform domain models to DTOs at boundary.

**Current Workaround:** Handler returns DTO directly, mixing concerns.

**Desired:**
```swift
// Option A: Transformer middleware
struct DTOTransformMiddleware: Middleware {
    func execute<T: Command>(...) async throws -> T.Result {
        let internalResult = try await next(command, context)

        if let transformable = internalResult as? DTOConvertible {
            return transformable.toDTO() as! T.Result
        }
        return internalResult
    }
}

// Option B: Pipeline-level transform
let publicPipeline = internalPipeline.mapResults { result in
    (result as? DTOConvertible)?.toDTO() ?? result
}

// Option C: Command declares both types
protocol TransformableCommand: Command {
    associatedtype InternalResult
    associatedtype ExternalResult = Result // defaults to same

    static func transform(_ internal: InternalResult) -> ExternalResult
}
```

**GournalCore Need:** Handlers should work with `JournalEntry` (domain model). API layer receives `EntryData` (DTO). Transformation should be automatic at boundary.

---

### 2.4 Middleware Ordering Improvements

**Problem:** Priority is a single Int. Complex ordering requirements are awkward.

**Current:** `ExecutionPriority` with predefined values (authentication=100, validation=200, etc.)

**Desired:**
```swift
// Option A: Before/After constraints
pipeline.addMiddleware(CacheMiddleware(), after: ValidationMiddleware.self)
pipeline.addMiddleware(EncryptionMiddleware(), before: HandlerExecution.self)

// Option B: Named phases
enum Phase: Int {
    case authentication = 100
    case authorization = 200
    case validation = 300
    case preProcessing = 400
    case execution = 500  // Handler runs here
    case postProcessing = 600
    case cleanup = 700
}

middleware.phase = .preProcessing
middleware.orderWithinPhase = 10

// Option C: Execution groups
pipeline.preExecution([ValidationMiddleware(), CacheCheckMiddleware()])
pipeline.postExecution([CacheWriteMiddleware(), AuditMiddleware()])
```

**GournalCore Need:** Some middleware must run before handler (decryption, validation), some after (encryption, indexing, embedding). Current priority system works but could be clearer.

---

## Tier 3: Nice to Have

### 3.1 Command Interception/Decoration

**Problem:** Can't easily wrap or modify commands before they reach handler.

**Desired:**
```swift
protocol CommandInterceptor {
    func intercept<T: Command>(_ command: T) -> T
}

// Example: Add default values, normalize input
struct NormalizationInterceptor: CommandInterceptor {
    func intercept<T: Command>(_ command: T) -> T {
        if var search = command as? SearchCommand {
            search.query = search.query.trimmingCharacters(in: .whitespaces)
            return search as! T
        }
        return command
    }
}
```

**GournalCore Need:** Input normalization, default value injection, request ID generation.

---

### 3.2 Pipeline Introspection API

**Problem:** Limited visibility into pipeline structure at runtime.

**Current:** `middlewareTypes`, `middlewareCount`, `hasMiddleware(ofType:)`

**Desired:**
```swift
pipeline.describe() -> PipelineDescription
// Returns: ordered list of middleware with their priorities, conditions, scopes

pipeline.trace(command) -> ExecutionPlan
// Returns: which middleware will execute for this command, in what order

pipeline.metrics() -> PipelineMetrics
// Returns: execution counts, timing percentiles per middleware
```

**GournalCore Need:** Debugging complex middleware chains, performance profiling.

---

### 3.3 Command Versioning/Migration

**Problem:** No support for evolving command schemas over time.

**Desired:**
```swift
protocol VersionedCommand: Command {
    static var version: Int { get }
}

// Migration support
struct CommandMigrator {
    func register<Old: Command, New: Command>(
        from: Old.Type,
        to: New.Type,
        migration: (Old) -> New
    )
}
```

**GournalCore Need:** If commands are persisted (for replay, undo, audit), need migration path.

---

### 3.4 Batching/Debouncing Middleware

**Problem:** High-frequency commands can overwhelm system.

**Desired:**
```swift
// Batch multiple commands into one
struct BatchingMiddleware<C: BatchableCommand>: Middleware {
    let maxBatchSize: Int
    let maxWait: Duration

    // Accumulates commands, executes as batch
}

// Debounce rapid-fire commands
struct DebouncingMiddleware: Middleware {
    let window: Duration
    // Only executes most recent command within window
}
```

**GournalCore Need:** Search-as-you-type could debounce. Bulk import could batch index updates.

---

### 3.5 Distributed Tracing Integration

**Problem:** TracingMiddleware exists but no OpenTelemetry/OTLP integration.

**Desired:**
```swift
struct OTLPTracingMiddleware: Middleware {
    let exporter: OTLPExporter

    // Creates spans with proper parent/child relationships
    // Propagates trace context through CommandContext
}
```

**GournalCore Need:** Production observability, especially for ML pipeline debugging.

---

## Tier 4: Future Considerations

### 4.1 Persistent Command Queue

For durable execution with at-least-once semantics. Commands survive app restarts.

### 4.2 Command Replay/Event Sourcing

Store commands as event log, rebuild state by replaying.

### 4.3 Multi-Pipeline Routing

Route commands to different pipelines based on runtime conditions (A/B testing, gradual rollout).

### 4.4 Remote Command Execution

Execute commands on a server, useful for compute-intensive ML operations.

---

## Summary: Priority Matrix

| Enhancement | Impact | Complexity | Recommended |
|-------------|--------|------------|-------------|
| Typed/Scoped Middleware | High | Medium | Yes |
| Deferred Commands | High | High | Yes |
| Command Composition | High | High | Yes |
| Progress/Streaming | High | Medium | Yes |
| Conditional Middleware | Medium | Low | Yes |
| Transaction Support | Medium | Medium | Yes |
| Result Transformation | Medium | Low | Yes |
| Middleware Ordering | Low | Low | Optional |
| Command Interception | Low | Low | Optional |
| Pipeline Introspection | Low | Low | Optional |
| Command Versioning | Low | Medium | Later |
| Batching/Debouncing | Low | Medium | Later |
| OTLP Tracing | Low | Medium | Later |

---

## Questions for Feasibility Review

1. **Typed Middleware:** Is the generic `execute<T: Command>` signature fundamental, or can we support type-constrained variants?

2. **Deferred Commands:** Should this be a separate module (PipelineKitAsync?) or core feature?

3. **Command Composition:** Prefer declarative chains, composite commands, or middleware-based approach?

4. **Progress Streaming:** AsyncStream integration - any concerns with backpressure or cancellation?

5. **Transaction Support:** Generic protocol vs SwiftData-specific module?

6. **Breaking Changes:** Which of these would require breaking the existing API?

---

*Document Version: 1.0*
*Created: December 2024*
