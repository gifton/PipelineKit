import Foundation
import PipelineKitCore

// MARK: - Operator Precedence Groups

precedencegroup MiddlewarePrecedence {
    associativity: left
    higherThan: AssignmentPrecedence
    lowerThan: AdditionPrecedence
}

// MARK: - Middleware Application Operators

/// Apply middleware to pipeline
infix operator <+: MiddlewarePrecedence

/// Apply middleware with priority
infix operator <++: MiddlewarePrecedence

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

// MARK: - Conditional Middleware Operators

/// Conditional middleware application
infix operator <?+: MiddlewarePrecedence

/// Apply middleware conditionally
public func <?+ <T: Command, H: CommandHandler>(
    handler: H,
    condition: @escaping @Sendable () async -> (Bool, any Middleware)
) async throws -> any Pipeline where H.CommandType == T {
    let (shouldApply, middleware) = await condition()
    let builder = PipelineBuilder(handler: handler)
    
    if shouldApply {
        return try await builder.with(middleware).build()
    } else {
        return try await builder.build()
    }
}

// MARK: - Middleware Chain Operators

/// Chain multiple middleware
infix operator +>+: MiddlewarePrecedence

/// Combine two middleware into a chain
public func +>+ (
    lhs: any Middleware,
    rhs: any Middleware
) -> MiddlewareChain {
    MiddlewareChain(middlewares: [lhs, rhs])
}

/// Helper type for chaining middleware
public struct MiddlewareChain: Middleware {
    public let priority = ExecutionPriority.processing
    private let middlewares: [any Middleware]
    
    public init(middlewares: [any Middleware]) {
        self.middlewares = middlewares
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Create a chain of middleware calls
        var chain = next
        
        // Wrap each middleware in reverse order
        for middleware in middlewares.reversed() {
            let currentMiddleware = middleware
            let currentChain = chain
            
            chain = { cmd, ctx in
                try await currentMiddleware.execute(cmd, context: ctx, next: currentChain)
            }
        }
        
        return try await chain(command, context)
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
/// let pipeline = try await handler
///     <++ middleware(AuthMiddleware(), priority: .authentication)
///     <++ middleware(ValidationMiddleware(), priority: .validation)
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
/// let debuggingPipeline = try await handler
///     <+ AuthenticationMiddleware()
///     <?+ when({ isDebugMode }, use: DebugLoggingMiddleware())
/// ```
///
/// - Parameters:
///   - condition: An async closure that returns whether the middleware should execute
///   - middleware: The middleware to execute conditionally
/// - Returns: A tuple that can be used with conditional middleware operators
/// - Note: The condition is evaluated each time a command flows through the pipeline
public func when(_ condition: @escaping @Sendable () async -> Bool, use middleware: any Middleware) -> (@Sendable () async -> Bool, any Middleware) {
    (condition, middleware)
}

/// Create a pipeline with middleware from a handler
public func pipeline<T: Command, H: CommandHandler>(
    for handler: H,
    middleware: [any Middleware] = []
) async throws -> any Pipeline where H.CommandType == T {
    var builder = PipelineBuilder(handler: handler)
    
    for mw in middleware {
        builder = await builder.with(mw)
    }
    
    return try await builder.build()
}

// MARK: - Usage Examples
/*
 // Apply single middleware
 let pipeline = try await handler <+ loggingMiddleware
 
 // Apply middleware with priority
 let pipeline = try await handler <++ (authMiddleware, .authentication)
 
 // Conditional middleware
 let pipeline = try await handler <?+ {
     let isDevelopment = await checkEnvironment()
     return (isDevelopment, debugMiddleware)
 }
 
 // Chain middleware
 let chain = authMiddleware +>+ validationMiddleware +>+ loggingMiddleware
 let pipeline = try await handler <+ chain
 
 // Using convenience function
 let pipeline = try await pipeline(
     for: handler,
     middleware: [authMiddleware, validationMiddleware, loggingMiddleware]
 )
 */