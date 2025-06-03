import Foundation

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

/// Apply conditional middleware
infix operator <?+: MiddlewarePrecedence

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

/// Apply conditional middleware
public func <?+ <T: Command, H: CommandHandler>(
    handler: H,
    conditionalMiddleware: (any Middleware, @Sendable () async -> Bool)
) async throws -> any Pipeline where H.CommandType == T {
    let conditional = ConditionalMiddlewareWrapper(
        middleware: conditionalMiddleware.0,
        condition: conditionalMiddleware.1
    )
    return try await PipelineBuilder(handler: handler)
        .with(conditional)
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
    
    public func execute<T: Command>(_ command: T, metadata: CommandMetadata) async throws -> T.Result {
        switch mode {
        case .sequential:
            // For sequential composition, we need a way to transform commands between pipelines
            // Since we can't change the command type, we'll use the result as context
            let firstResult = try await first.execute(command, metadata: metadata)
            
            // Create a new command that wraps the original command and the first result
            if let chainableCommand = command as? any ChainableCommand {
                let chainedCommand = chainableCommand.chain(with: firstResult) as! T
                return try await second.execute(chainedCommand, metadata: metadata)
            } else {
                // Fallback: execute with original command if not chainable
                return try await second.execute(command, metadata: metadata)
            }
            
        case .parallel(let strategy):
            switch strategy {
            case .firstCompleted:
                return try await withThrowingTaskGroup(of: T.Result.self) { group in
                    group.addTask {
                        try await self.first.execute(command, metadata: metadata)
                    }
                    group.addTask {
                        try await self.second.execute(command, metadata: metadata)
                    }
                    
                    guard let result = try await group.next() else {
                        throw PipelineError.executionFailed("No pipeline completed successfully")
                    }
                    
                    group.cancelAll()
                    return result
                }
                
            case .allCompleted:
                return try await withThrowingTaskGroup(of: T.Result.self) { group in
                    group.addTask {
                        try await self.first.execute(command, metadata: metadata)
                    }
                    group.addTask {
                        try await self.second.execute(command, metadata: metadata)
                    }
                    
                    var results: [T.Result] = []
                    for try await result in group {
                        results.append(result)
                    }
                    
                    // Return the last result (or could be configured to merge results)
                    guard let finalResult = results.last else {
                        throw PipelineError.executionFailed("No pipeline completed successfully")
                    }
                    return finalResult
                }
                
            case .race:
                return try await withThrowingTaskGroup(of: Result<T.Result, Error>.self) { group in
                    group.addTask {
                        do {
                            return .success(try await self.first.execute(command, metadata: metadata))
                        } catch {
                            return .failure(error)
                        }
                    }
                    group.addTask {
                        do {
                            return .success(try await self.second.execute(command, metadata: metadata))
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
                    
                    throw PipelineError.allPipelinesFailed(errors)
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
    
    public func execute<T: Command>(_ command: T, metadata: CommandMetadata) async throws -> T.Result {
        if await condition() {
            return try await pipeline.execute(command, metadata: metadata)
        } else if let defaultResult = defaultResult {
            // Attempt to provide a default result
            let result = try await defaultResult()
            if let typedResult = result as? T.Result {
                return typedResult
            } else {
                throw PipelineError.executionFailed(
                    "Default result type \(type(of: result)) does not match expected type \(T.Result.self)"
                )
            }
        } else {
            // Check if the command type provides a default result
            if let defaultProvider = command as? any DefaultResultProvider {
                return defaultProvider.defaultResult() as! T.Result
            }
            throw PipelineError.conditionNotMet("Pipeline condition not satisfied and no default result provided")
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
    
    public func execute<T: Command>(_ command: T, metadata: CommandMetadata) async throws -> T.Result {
        do {
            return try await pipeline.execute(command, metadata: metadata)
        } catch {
            try await errorHandler(error)
            throw error
        }
    }
}

// MARK: - Fluent Pipeline Builder with Operators

/// A fluent interface builder for constructing pipelines using operator syntax.
///
/// This builder implements the **Fluent Interface** design pattern, allowing you to
/// chain middleware additions in a readable, expressive way that flows like natural language.
/// It supports custom operators for an even more intuitive developer experience.
///
/// ## What Makes It "Fluent"?
///
/// Traditional approach requires multiple separate calls:
/// ```swift
/// let builder = PipelineBuilder(handler: userHandler)
/// await builder.with(authMiddleware)
/// await builder.with(validationMiddleware)
/// let pipeline = try await builder.build()
/// ```
///
/// Fluent approach chains operations naturally:
/// ```swift
/// let pipeline = try await pipeline(for: userHandler)
///     <+ authMiddleware
///     <++ middleware(validationMiddleware, priority: .validation)
///     <+ loggingMiddleware
///     .build()
/// ```
///
/// ## Available Operators
///
/// - `<+` - Adds middleware without priority
/// - `<++` - Adds middleware with execution priority
///
/// ## Usage Examples
///
/// ### Basic middleware chain:
/// ```swift
/// let pipeline = try await pipeline(for: CreateUserHandler())
///     <+ AuthenticationMiddleware()
///     <+ ValidationMiddleware()
///     <+ LoggingMiddleware()
///     .build()
/// ```
///
/// ### With execution priorities:
/// ```swift
/// let pipeline = try await pipeline(for: handler)
///     <++ middleware(AuthMiddleware(), priority: .authentication)
///     <++ middleware(ValidationMiddleware(), priority: .validation)
///     <+ LoggingMiddleware()  // No priority needed
///     .build()
/// ```
///
/// ### Mixed with conditional logic:
/// ```swift
/// let pipeline = try await pipeline(for: handler)
///     <+ AuthenticationMiddleware()
///     <+ (isProduction ? ProductionLoggingMiddleware() : DebugMiddleware())
///     <+ ValidationMiddleware()
///     .build()
/// ```
///
/// ## Benefits
///
/// - **Readability**: Code reads naturally from top to bottom
/// - **Type Safety**: Compile-time validation of the entire chain  
/// - **Discoverability**: IDE auto-completion guides you through options
/// - **Maintainability**: Easy to add, remove, or reorder middleware
/// - **Expressiveness**: Operators make intent clear and concise
///
/// ## Performance Notes
///
/// The fluent builder collects components during chaining and processes them
/// efficiently in a single pass during `build()`. There's no performance penalty
/// compared to traditional builder patterns.
public struct FluentPipelineBuilder<T: Command, H: CommandHandler> where H.CommandType == T {
    /// The middleware components to be applied to the pipeline
    private var components: [PipelineComponent] = []
    
    /// The command handler that will process commands after all middleware
    private let handler: H
    
    /// Creates a new fluent pipeline builder with the specified handler.
    ///
    /// - Parameter handler: The command handler that will process commands
    public init(handler: H) {
        self.handler = handler
    }
    
    /// Adds middleware to the pipeline using the `<+` operator.
    ///
    /// This is the basic middleware addition operator. Middleware added with this
    /// operator will execute in the order they were added to the chain.
    ///
    /// Example:
    /// ```swift
    /// let pipeline = pipeline(for: handler)
    ///     <+ AuthenticationMiddleware()
    ///     <+ LoggingMiddleware()
    /// ```
    ///
    /// - Parameters:
    ///   - lhs: The current pipeline builder
    ///   - middleware: The middleware to add to the pipeline
    /// - Returns: A new builder instance with the middleware added
    public static func <+ (lhs: FluentPipelineBuilder<T, H>, middleware: any Middleware) -> FluentPipelineBuilder<T, H> {
        var builder = lhs
        builder.components.append(.middleware(middleware, order: nil))
        return builder
    }
    
    /// Adds middleware with execution priority using the `<++` operator.
    ///
    /// This operator allows you to specify the execution order of middleware
    /// using predefined priority levels. Use this when you need precise control
    /// over when middleware executes relative to others.
    ///
    /// Example:
    /// ```swift
    /// let pipeline = pipeline(for: handler)
    ///     <++ middleware(AuthMiddleware(), priority: .authentication)
    ///     <++ middleware(ValidationMiddleware(), priority: .validation)
    /// ```
    ///
    /// - Parameters:
    ///   - lhs: The current pipeline builder
    ///   - middlewareWithPriority: A tuple containing the middleware and its execution priority
    /// - Returns: A new builder instance with the prioritized middleware added
    public static func <++ (
        lhs: FluentPipelineBuilder<T, H>, 
        middlewareWithPriority: (any Middleware, ExecutionPriority)
    ) -> FluentPipelineBuilder<T, H> {
        var builder = lhs
        builder.components.append(.middleware(middlewareWithPriority.0, order: middlewareWithPriority.1))
        return builder
    }
    
    /// Builds the final pipeline from the accumulated middleware components.
    ///
    /// This method processes all middleware added via the fluent chain and
    /// constructs the final pipeline instance. The middleware will be applied
    /// in the order they were added, with any priority-based middleware sorted
    /// according to their execution priority.
    ///
    /// - Returns: A configured pipeline ready for command execution
    /// - Throws: `PipelineError` if there are issues with the configuration
    public func build() async throws -> any Pipeline {
        let builder = PipelineBuilder(handler: handler)
        
        // First, sort components by priority if specified
        let sortedComponents = sortComponentsByPriority(components)
        
        // Process each component
        for component in sortedComponents {
            switch component {
            case .middleware(let middleware, _):
                await builder.with(middleware)
                
            case .conditional(let condition, let middleware):
                let wrapper = ConditionalMiddlewareWrapper(
                    middleware: middleware,
                    condition: condition
                )
                await builder.with(wrapper)
                
            case .group(let groupComponents, _):
                // Recursively process group components
                let sortedGroup = sortComponentsByPriority(groupComponents)
                for groupComponent in sortedGroup {
                    await processComponent(groupComponent, builder: builder)
                }
                
            case .parallel(let middlewares):
                // Create a parallel middleware wrapper
                let parallelWrapper = ParallelMiddlewareWrapper(middlewares: middlewares)
                await builder.with(parallelWrapper)
                
            case .retry(let middleware, let maxAttempts, let backoff):
                // Create retry wrapper with the specified strategy
                let retryWrapper = RetryMiddlewareWrapper(
                    middleware: middleware,
                    maxAttempts: maxAttempts,
                    strategy: backoff
                )
                await builder.with(retryWrapper)
                
            case .timeout(let middleware, let duration):
                // Create timeout wrapper
                let timeoutWrapper = TimeoutMiddlewareWrapper(
                    middleware: middleware,
                    timeout: duration
                )
                await builder.with(timeoutWrapper)
            }
        }
        
        return try await builder.build()
    }
    
    /// Sorts components by their execution priority
    private func sortComponentsByPriority(_ components: [PipelineComponent]) -> [PipelineComponent] {
        return components.sorted { first, second in
            let firstPriority = extractPriority(from: first)
            let secondPriority = extractPriority(from: second)
            
            // If both have priorities, sort by priority value (lower values execute first)
            if let p1 = firstPriority, let p2 = secondPriority {
                return p1.rawValue < p2.rawValue
            }
            
            // Components with priority come before those without
            if firstPriority != nil && secondPriority == nil {
                return true
            }
            if firstPriority == nil && secondPriority != nil {
                return false
            }
            
            // Both nil priorities - maintain original order
            return false
        }
    }
    
    /// Extracts the priority from a pipeline component
    private func extractPriority(from component: PipelineComponent) -> ExecutionPriority? {
        switch component {
        case .middleware(_, let order):
            return order
        case .group(_, let order):
            return order
        default:
            return nil
        }
    }
    
    /// Processes a single component and adds it to the builder
    private func processComponent(_ component: PipelineComponent, builder: PipelineBuilder<T, H>) async {
        switch component {
        case .middleware(let middleware, _):
            await builder.with(middleware)
        case .conditional(let condition, let middleware):
            let wrapper = ConditionalMiddlewareWrapper(
                middleware: middleware,
                condition: condition
            )
            await builder.with(wrapper)
        case .group(let groupComponents, _):
            let sortedGroup = sortComponentsByPriority(groupComponents)
            for groupComponent in sortedGroup {
                await processComponent(groupComponent, builder: builder)
            }
        case .parallel(let middlewares):
            let parallelWrapper = ParallelMiddlewareWrapper(middlewares: middlewares)
            await builder.with(parallelWrapper)
        case .retry(let middleware, let maxAttempts, let backoff):
            let retryWrapper = RetryMiddlewareWrapper(
                middleware: middleware,
                maxAttempts: maxAttempts,
                strategy: backoff
            )
            await builder.with(retryWrapper)
        case .timeout(let middleware, let duration):
            let timeoutWrapper = TimeoutMiddlewareWrapper(
                middleware: middleware,
                timeout: duration
            )
            await builder.with(timeoutWrapper)
        }
    }
}

// MARK: - Convenience Functions

/// Creates a fluent pipeline builder for the specified command handler.
///
/// This is the entry point for creating pipelines using the fluent interface.
/// It returns a `FluentPipelineBuilder` that supports operator chaining for
/// an expressive, readable pipeline construction experience.
///
/// Example:
/// ```swift
/// let userPipeline = try await pipeline(for: CreateUserHandler())
///     <+ AuthenticationMiddleware()
///     <+ ValidationMiddleware()
///     <+ LoggingMiddleware()
///     .build()
/// ```
///
/// - Parameter handler: The command handler that will process commands after middleware
/// - Returns: A fluent pipeline builder ready for middleware chaining
/// - Note: The returned builder uses generic constraints to ensure type safety
///         between the handler and the commands it processes
public func pipeline<T: Command, H: CommandHandler>(for handler: H) -> FluentPipelineBuilder<T, H> where H.CommandType == T {
    FluentPipelineBuilder(handler: handler)
}

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

// MARK: - Extended Pipeline Error Types

extension PipelineError {
    static func conditionNotMet(_ message: String) -> PipelineError {
        .executionFailed("Condition not met: \(message)")
    }
    
    static func allPipelinesFailed(_ errors: [Error]) -> PipelineError {
        let errorDescriptions = errors.map { $0.localizedDescription }.joined(separator: "; ")
        return .executionFailed("All pipelines failed: \(errorDescriptions)")
    }
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
