import Foundation

/// A protocol that defines cross-cutting functionality in the command pipeline.
///
/// Middleware components intercept command execution to provide features like
/// authentication, validation, logging, caching, and error handling. They form
/// a chain of responsibility where each middleware can process the command before
/// and/or after passing it to the next component in the chain.
///
/// ## Overview
///
/// Middleware follows the chain of responsibility pattern, where each middleware:
/// - Receives a command and context
/// - Can modify the context or validate the command
/// - Decides whether to pass execution to the next middleware
/// - Can process the result after the chain completes
///
/// ## Execution Order
///
/// Middleware execution order is determined by the `priority` property. The pipeline
/// sorts middleware by priority before building the execution chain. Standard priorities
/// include:
/// - `.authentication` (1000): Verify user identity
/// - `.authorization` (900): Check permissions
/// - `.validation` (800): Validate command data
/// - `.preProcessing` (500): Transform or enrich data
/// - `.postProcessing` (100): Process results
/// - `.custom` (0): Default priority
///
/// ## Thread Safety
///
/// All middleware must be `Sendable` to ensure thread safety in concurrent environments.
/// Avoid storing mutable state in middleware instances.
///
/// ## Example
///
/// ```swift
/// struct LoggingMiddleware: Middleware {
///     let priority = ExecutionPriority.postProcessing
///
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @escaping MiddlewareNext<T>
///     ) async throws -> T.Result {
///         let start = Date()
///         do {
///             let result = try await next(command, context)
///             print("Command \(T.self) succeeded in \(Date().timeIntervalSince(start))s")
///             return result
///         } catch {
///             print("Command \(T.self) failed: \(error)")
///             throw error
///         }
///     }
/// }
/// ```
///
/// - SeeAlso: `ExecutionPriority`, `Pipeline`, `Command`
public protocol Middleware: Sendable {
    /// The priority of the middleware, which determines its execution order.
    ///
    /// Higher priority values execute first. Use predefined priorities from
    /// `ExecutionPriority` or create custom values.
    var priority: ExecutionPriority { get }

    /// Executes the middleware logic for a command.
    ///
    /// This method receives a command and can:
    /// - Validate or transform the command
    /// - Modify the context
    /// - Call the next middleware in the chain
    /// - Process the result
    /// - Handle errors
    ///
    /// - Parameters:
    ///   - command: The command being executed
    ///   - context: The command context containing metadata and shared data
    ///   - next: The next handler in the chain (middleware or final handler)
    ///
    /// - Returns: The result of command execution
    ///
    /// - Throws: Any error that occurs during execution. Middleware can catch
    ///   and handle errors from the chain, or propagate them up.
    ///
    /// - Note: Always call `next` unless you intentionally want to short-circuit
    ///   the pipeline (e.g., for caching or authorization failures).
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}

// MARK: - Middleware Typealiases

/// Typealias for the middleware next closure.
///
/// This type alias simplifies middleware signatures by providing a shorter,
/// more readable name for the continuation function that invokes the next
/// middleware in the chain or the final command handler.
///
/// ## Usage
///
/// Instead of writing the full closure signature:
/// ```swift
/// next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
/// ```
///
/// You can use the more concise form:
/// ```swift
/// next: @escaping MiddlewareNext<T>
/// ```
///
/// Both forms are completely equivalent and fully compatible. The typealias
/// is purely for improved readability and maintainability.
///
/// ## Example
///
/// ```swift
/// struct LoggingMiddleware: Middleware {
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @escaping MiddlewareNext<T>  // ✅ Cleaner signature
///     ) async throws -> T.Result {
///         print("Executing: \(T.self)")
///         return try await next(command, context)
///     }
/// }
/// ```
///
/// ## Before and After
///
/// **Before:**
/// ```swift
/// func execute<T: Command>(
///     _ command: T,
///     context: CommandContext,
///     next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
/// ) async throws -> T.Result
/// ```
///
/// **After:**
/// ```swift
/// func execute<T: Command>(
///     _ command: T,
///     context: CommandContext,
///     next: @escaping MiddlewareNext<T>
/// ) async throws -> T.Result
/// ```
///
/// - Note: This typealias is compile-time only and has zero runtime overhead.
///
/// - SeeAlso: `Middleware`
public typealias MiddlewareNext<T: Command> = @Sendable (T, CommandContext) async throws -> T.Result

// Add extension for default priority
public extension Middleware {
    /// Default priority for middleware when not specified.
    ///
    /// - Note: Custom middleware should explicitly set priority when order matters.
    var priority: ExecutionPriority { .custom }
}

/// A marker protocol for middleware that opt out of automatic NextGuard safety.
///
/// ## WARNING: Use at Your Own Risk
///
/// Conforming to this protocol disables the automatic NextGuard wrapper that ensures
/// `next` is called exactly once. You become fully responsible for:
/// - Ensuring `next` is called exactly once (unless explicitly short-circuiting)
/// - Managing the lifecycle of the `next` closure if stored
/// - Preventing memory leaks from retain cycles
/// - Avoiding duplicated side effects from multiple calls
///
/// ## When to Use
///
/// Only conform to `UnsafeMiddleware` when you need to:
/// - Implement custom retry/replay logic
/// - Build performance-critical middleware with guaranteed single execution
/// - Create testing/debugging middleware that intentionally calls next multiple times
/// - Provide your own safety mechanisms
///
/// ## Example
///
/// ```swift
/// struct CustomRetryMiddleware: Middleware, UnsafeMiddleware {
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @escaping MiddlewareNext<T>
///     ) async throws -> T.Result {
///         // Custom logic that might call next multiple times
///         var lastError: Error?
///         for attempt in 1...3 {
///             do {
///                 return try await next(command, context)
///             } catch {
///                 lastError = error
///                 if attempt < 3 {
///                     try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
///                 }
///             }
///         }
///         throw lastError ?? PipelineError.retryExhausted(attempts: 3, lastError: nil)
///     }
/// }
/// ```
///
/// - Warning: Violations of the exactly-once guarantee can corrupt the pipeline state,
///   cause memory leaks, undefined behavior, or duplicated side effects.
///
/// - SeeAlso: `Middleware`, `NextGuard`
public protocol UnsafeMiddleware: Middleware {
    // Marker protocol - no additional requirements
}

/// A marker protocol for middleware that want to suppress NextGuard deinit warnings.
///
/// Conform when middleware may intentionally not call `next` under normal,
/// non-error conditions and the lack of a call should not surface as a debug warning
/// (for example, caching or fast-path short-circuiting). This affects only debug
/// deinit warnings; it does not change NextGuard's runtime safety checks.
public protocol NextGuardWarningSuppressing: Middleware {
    // Marker protocol - no additional requirements
}
