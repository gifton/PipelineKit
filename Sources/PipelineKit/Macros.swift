/// A macro that generates Pipeline protocol conformance and implementation for types.
///
/// The `@Pipeline` macro automatically:
/// - Adds conformance to the `Pipeline` protocol
/// - Generates an internal `_executor` property
/// - Implements the `execute(_:metadata:)` method
/// - Implements the `batchExecute(_:metadata:)` method
/// - Optionally sets up middleware if specified
///
/// ## Requirements
///
/// The type must have:
/// - A `typealias CommandType` that specifies the command type
/// - A `handler` property that conforms to `CommandHandler`
///
/// ## Basic Usage
///
/// ```swift
/// @Pipeline
/// actor UserService {
///     typealias CommandType = CreateUserCommand
///     let handler = CreateUserHandler()
/// }
/// ```
///
/// ## Advanced Usage
///
/// ```swift
/// @Pipeline(
///     concurrency: .limited(10),
///     middleware: [AuthenticationMiddleware.self, ValidationMiddleware.self],
///     maxDepth: 50,
///     context: .enabled
/// )
/// actor UserService {
///     typealias CommandType = CreateUserCommand
///     let handler = CreateUserHandler()
/// }
/// ```
///
/// - Parameters:
///   - concurrency: The concurrency strategy (`.unlimited` or `.limited(n)`)
///   - middleware: Array of middleware types to apply
///   - maxDepth: Maximum recursion depth (default: 100)
///   - context: Whether to use context-aware pipeline (`.enabled` or `.disabled`)
@attached(member, names: named(_executor), named(execute), named(batchExecute), named(setupMiddleware))
@attached(extension, conformances: Pipeline)
public macro Pipeline(
    concurrency: ConcurrencyStrategy = .unlimited,
    middleware: [Any.Type] = [],
    maxDepth: Int = 100,
    context: ContextOption = .disabled
) = #externalMacro(module: "PipelineMacros", type: "PipelineMacro")

/// Concurrency strategy for the pipeline
public enum ConcurrencyStrategy {
    /// No limit on concurrent executions
    case unlimited
    /// Limited to a specific number of concurrent executions
    case limited(Int)
}

/// Context option for the pipeline
public enum ContextOption {
    /// Use standard pipeline without context
    case disabled
    /// Use context-aware pipeline
    case enabled
}