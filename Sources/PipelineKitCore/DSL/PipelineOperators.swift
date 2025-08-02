import Foundation

// MARK: - Error Types

struct NoResultError: LocalizedError {
    var errorDescription: String? { "No pipeline completed successfully" }
}

struct TypeMismatchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ConditionNotMetError: LocalizedError {
    let message: String
    var errorDescription: String? { "Condition not met: \(message)" }
}

struct AllPipelinesFailedError: LocalizedError {
    let errors: [Error]
    var errorDescription: String? {
        let errorDescriptions = errors.map { $0.localizedDescription }.joined(separator: "; ")
        return "All pipelines failed: \(errorDescriptions)"
    }
}

// MARK: - Protocol for Chainable Commands

/// Protocol for commands that can be chained with results from previous pipeline executions
public protocol ChainableCommand: Command {
    /// Creates a new command instance that incorporates the result from a previous execution
    func chain(with previousResult: Any) -> any Command
}

/// Protocol for commands that can provide a default result when pipeline conditions aren't met
public protocol DefaultResultProvider: Command {
    /// Provides a default result when the pipeline cannot execute
    func defaultResult() -> Result
}

// MARK: - Operator Precedence Groups

precedencegroup PipelinePrecedence {
    associativity: left
    higherThan: AssignmentPrecedence
    lowerThan: TernaryPrecedence
}

precedencegroup MiddlewarePrecedence {
    associativity: left
    higherThan: PipelinePrecedence
    lowerThan: AdditionPrecedence
}

// MARK: - Pipeline Composition Operators

/// Pipeline composition operator - combines pipelines sequentially
infix operator |>: PipelinePrecedence

/// Reverse pipeline composition operator
infix operator <|: PipelinePrecedence

/// Parallel pipeline composition operator
infix operator <>: PipelinePrecedence

/// Conditional pipeline operator
infix operator |?: PipelinePrecedence

/// Error handling pipeline operator  
infix operator |!: PipelinePrecedence

// MARK: - Middleware Application Operators

/// Apply middleware to pipeline
infix operator <+: MiddlewarePrecedence

/// Apply middleware with priority
infix operator <++: MiddlewarePrecedence


// MARK: - Pipeline Composition Implementations

/// Sequential pipeline composition
public func |> (
    lhs: any Pipeline,
    rhs: any Pipeline
) -> CompositePipeline {
    CompositePipeline(first: lhs, second: rhs, mode: .sequential)
}

/// Reverse pipeline composition (more functional style)
public func <| (
    lhs: any Pipeline,
    rhs: any Pipeline
) -> CompositePipeline {
    CompositePipeline(first: rhs, second: lhs, mode: .sequential)
}

/// Parallel pipeline composition
public func <> (
    lhs: any Pipeline,
    rhs: any Pipeline
) -> CompositePipeline {
    CompositePipeline(first: lhs, second: rhs, mode: .parallel(strategy: .firstCompleted))
}

/// Conditional pipeline composition
public func |? (
    lhs: any Pipeline,
    condition: @escaping @Sendable () async -> Bool
) -> ConditionalPipelineWrapper {
    ConditionalPipelineWrapper(pipeline: lhs, condition: condition)
}

/// Conditional pipeline composition with default result
public func |? (
    lhs: any Pipeline,
    conditionWithDefault: (condition: @Sendable () async -> Bool, defaultResult: @Sendable () async throws -> Any)
) -> ConditionalPipelineWrapper {
    ConditionalPipelineWrapper(
        pipeline: lhs, 
        condition: conditionWithDefault.condition,
        defaultResult: conditionWithDefault.defaultResult
    )
}

/// Error handling pipeline composition
public func |! (
    lhs: any Pipeline,
    errorHandler: @escaping @Sendable (Error) async throws -> Void
) -> ErrorHandlingPipelineWrapper {
    ErrorHandlingPipelineWrapper(pipeline: lhs, errorHandler: errorHandler)
}

// MARK: - Middleware Application Implementations

/// Apply middleware to handler
public func <+ <T: Command, H: CommandHandler>(
    handler: H,
    middleware: any Middleware
) async throws -> any Pipeline where H.CommandType == T {
    try await PipelineBuilder(handler: handler)
        .with(middleware)
        .build()
}

/// Apply middleware with priority
public func <++ <T: Command, H: CommandHandler>(
    handler: H,
    middlewareWithPriority: (any Middleware, ExecutionPriority)
) async throws -> any Pipeline where H.CommandType == T {
    try await PipelineBuilder(handler: handler)
        .with(middlewareWithPriority.0)
        .build()
}


// MARK: - Helper Types for Operators

/// Composite pipeline that combines two pipelines
public struct CompositePipeline: Pipeline {
    private let first: any Pipeline
    private let second: any Pipeline
    private let mode: CompositionMode
    
    public enum CompositionMode: Sendable {
        case sequential
        case parallel(strategy: ParallelStrategy = .firstCompleted)
    }
    
    public enum ParallelStrategy: Sendable {
        case firstCompleted
        case allCompleted
        case race // Returns first success or all failures
    }
    
    init(first: any Pipeline, second: any Pipeline, mode: CompositionMode) {
        self.first = first
        self.second = second
        self.mode = mode
    }
    
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        switch mode {
        case .sequential:
            // For sequential composition, we need a way to transform commands between pipelines
            // Since we can't change the command type, we'll use the result as context
            let firstResult = try await first.execute(command, context: context)
            
            // Create a new command that wraps the original command and the first result
            if let chainableCommand = command as? any ChainableCommand {
                let chainedCommand = chainableCommand.chain(with: firstResult) as! T
                return try await second.execute(chainedCommand, context: context)
            } else {
                // Fallback: execute with original command if not chainable
                return try await second.execute(command, context: context)
            }
            
        case .parallel(let strategy):
            switch strategy {
            case .firstCompleted:
                return try await withThrowingTaskGroup(of: T.Result.self) { group in
                    group.addTask {
                        try await self.first.execute(command, context: context)
                    }
                    group.addTask {
                        try await self.second.execute(command, context: context)
                    }
                    
                    guard let result = try await group.next() else {
                        throw PipelineError.executionFailed(
                            message: "No pipeline completed successfully",
                            context: nil
                        )
                    }
                    
                    group.cancelAll()
                    return result
                }
                
            case .allCompleted:
                return try await withThrowingTaskGroup(of: T.Result.self) { group in
                    group.addTask {
                        try await self.first.execute(command, context: context)
                    }
                    group.addTask {
                        try await self.second.execute(command, context: context)
                    }
                    
                    var results: [T.Result] = []
                    for try await result in group {
                        results.append(result)
                    }
                    
                    // Return the last result (or could be configured to merge results)
                    guard let finalResult = results.last else {
                        throw PipelineError.executionFailed(
                            message: "No pipeline completed successfully",
                            context: nil
                        )
                    }
                    return finalResult
                }
                
            case .race:
                return try await withThrowingTaskGroup(of: Result<T.Result, Error>.self) { group in
                    group.addTask {
                        do {
                            return .success(try await self.first.execute(command, context: context))
                        } catch {
                            return .failure(error)
                        }
                    }
                    group.addTask {
                        do {
                            return .success(try await self.second.execute(command, context: context))
                        } catch {
                            return .failure(error)
                        }
                    }
                    
                    var errors: [Error] = []
                    for try await result in group {
                        switch result {
                        case .success(let value):
                            group.cancelAll()
                            return value
                        case .failure(let error):
                            errors.append(error)
                        }
                    }
                    
                    throw PipelineError.parallelExecutionFailed(errors: errors)
                }
            }
        }
    }
}

/// Conditional pipeline wrapper
public struct ConditionalPipelineWrapper: Pipeline {
    private let pipeline: any Pipeline
    private let condition: @Sendable () async -> Bool
    private let defaultResult: (@Sendable () async throws -> Any)?
    
    init(pipeline: any Pipeline, 
         condition: @escaping @Sendable () async -> Bool,
         defaultResult: (@Sendable () async throws -> Any)? = nil) {
        self.pipeline = pipeline
        self.condition = condition
        self.defaultResult = defaultResult
    }
    
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        if await condition() {
            return try await pipeline.execute(command, context: context)
        } else if let defaultResult = defaultResult {
            // Attempt to provide a default result
            let result = try await defaultResult()
            if let typedResult = result as? T.Result {
                return typedResult
            } else {
                throw PipelineError.executionFailed(
                    message: "Default result type \(type(of: result)) does not match expected type \(T.Result.self)",
                    context: nil
                )
            }
        } else {
            // Check if the command type provides a default result
            if let defaultProvider = command as? any DefaultResultProvider {
                return defaultProvider.defaultResult() as! T.Result
            }
            throw PipelineError.executionFailed(
                message: "Pipeline condition not satisfied and no default result provided",
                context: nil
            )
        }
    }
}

/// Error handling pipeline wrapper
public struct ErrorHandlingPipelineWrapper: Pipeline {
    private let pipeline: any Pipeline
    private let errorHandler: @Sendable (Error) async throws -> Void
    
    init(pipeline: any Pipeline, errorHandler: @escaping @Sendable (Error) async throws -> Void) {
        self.pipeline = pipeline
        self.errorHandler = errorHandler
    }
    
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        do {
            return try await pipeline.execute(command, context: context)
        } catch {
            try await errorHandler(error)
            throw error
        }
    }
}

// MARK: - Convenience Functions

/// Creates a middleware-priority tuple for use with the `<++` operator.
///
/// This convenience function creates the tuple format expected by the priority
/// middleware operator (`<++`). It makes the syntax cleaner when you need to
/// specify execution priorities.
///
/// Example:
/// ```swift
/// let pipeline = try await pipeline(for: handler)
///     <++ middleware(AuthMiddleware(), priority: .authentication)
///     <++ middleware(ValidationMiddleware(), priority: .validation)
///     .build()
/// ```
///
/// - Parameters:
///   - middleware: The middleware to be executed
///   - priority: The execution priority level
/// - Returns: A tuple that can be used with the `<++` operator
public func middleware(_ middleware: any Middleware, priority: ExecutionPriority) -> (any Middleware, ExecutionPriority) {
    (middleware, priority)
}

/// Creates a conditional middleware tuple for conditional execution patterns.
///
/// This function creates middleware that only executes when a condition is met.
/// The condition is evaluated at runtime before the middleware executes.
///
/// Example:
/// ```swift
/// let debuggingPipeline = try await pipeline(for: handler)
///     <+ AuthenticationMiddleware()
///     <+ when({ isDebugMode }, use: DebugLoggingMiddleware())
///     .build()
/// ```
///
/// - Parameters:
///   - condition: An async closure that returns whether the middleware should execute
///   - middleware: The middleware to execute conditionally
/// - Returns: A tuple that can be used with conditional middleware operators
/// - Note: The condition is evaluated each time a command flows through the pipeline
public func when(_ condition: @escaping @Sendable () async -> Bool, use middleware: any Middleware) -> (any Middleware, @Sendable () async -> Bool) {
    (middleware, condition)
}


// MARK: - Additional Convenience Functions

/// Creates a parallel execution strategy configuration
public func parallel(strategy: CompositePipeline.ParallelStrategy) -> CompositePipeline.ParallelStrategy {
    strategy
}

/// Creates a conditional configuration with default result
public func whenElse<T>(
    _ condition: @escaping @Sendable () async -> Bool,
    defaultResult: @escaping @Sendable () async throws -> T
) -> (condition: @Sendable () async -> Bool, defaultResult: @Sendable () async throws -> Any) {
    (condition, { try await defaultResult() as Any })
}

// MARK: - Operator Usage Examples

/*
Example usage of operators:

```swift
// Basic middleware application
let pipeline1 = try handler <+ authMiddleware <+ loggingMiddleware

// With priorities
let pipeline2 = try handler <++ middleware(authMiddleware, priority: .authentication)
                           <++ middleware(loggingMiddleware, priority: .logging)

// Conditional middleware  
let pipeline3 = try handler <?+ when({ await isDevelopment() }, use: debugMiddleware)

// Pipeline composition with result chaining (for ChainableCommand)
let compositePipeline = pipeline1 |> pipeline2

// Parallel execution with different strategies
let parallelPipeline = pipeline1 <> pipeline2  // Default: firstCompleted

// Create custom parallel pipeline with strategy
let racePipeline = CompositePipeline(
    first: pipeline1, 
    second: pipeline2, 
    mode: .parallel(strategy: .race)
)

// Conditional execution with default result
let conditionalPipeline = pipeline1 |? whenElse(
    { await shouldExecute() },
    defaultResult: { MyDefaultResult() }
)

// Error handling
let safePipeline = pipeline1 |! { error in
    await logError(error)
}

// Fluent builder style with all component types
let fluentPipeline = try pipeline(for: handler)
    <+ authMiddleware
    <++ middleware(validationMiddleware, priority: .validation)
    <+ loggingMiddleware
    .build()
```
*/
