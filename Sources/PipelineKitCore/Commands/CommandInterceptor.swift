import Foundation

/// A protocol for intercepting and potentially transforming commands before pipeline execution.
///
/// Command interceptors provide a pre-execution hook that runs before the middleware chain.
/// They can modify, normalize, or enrich commands before they enter the pipeline.
///
/// ## Overview
///
/// Interceptors are useful for:
/// - **Input normalization**: Trimming whitespace, normalizing case, etc.
/// - **Default value injection**: Adding default values to optional fields
/// - **Request ID generation**: Assigning unique identifiers to commands
/// - **Command enrichment**: Adding derived or computed properties
/// - **Pre-validation transformations**: Converting input formats
///
/// ## Execution Order
///
/// Interceptors run **before** the middleware chain:
///
/// ```
/// Command → [Interceptor Chain] → [Middleware Chain] → Handler → Result
/// ```
///
/// This means interceptors can modify the command that middleware sees,
/// but they don't have access to execution context or the result.
///
/// ## Type Safety
///
/// Interceptors receive and return commands through a generic interface.
/// If the command type doesn't match what the interceptor handles, it
/// should return the command unchanged.
///
/// ## Example: Input Normalization
///
/// ```swift
/// struct SearchNormalizationInterceptor: CommandInterceptor {
///     func intercept<T: Command>(_ command: T) -> T {
///         guard var search = command as? SearchCommand else {
///             return command
///         }
///         search.query = search.query.trimmingCharacters(in: .whitespaces)
///         search.query = search.query.lowercased()
///         return search as! T
///     }
/// }
/// ```
///
/// ## Example: Request ID Injection
///
/// ```swift
/// struct RequestIDInterceptor: CommandInterceptor {
///     func intercept<T: Command>(_ command: T) -> T {
///         guard var identifiable = command as? any IdentifiableCommand else {
///             return command
///         }
///         if identifiable.requestId == nil {
///             identifiable.requestId = UUID().uuidString
///         }
///         return identifiable as! T
///     }
/// }
/// ```
///
/// ## Example: Default Values
///
/// ```swift
/// struct PaginationDefaultsInterceptor: CommandInterceptor {
///     let defaultPageSize: Int = 20
///     let defaultPage: Int = 1
///
///     func intercept<T: Command>(_ command: T) -> T {
///         guard var paginated = command as? any PaginatedCommand else {
///             return command
///         }
///         if paginated.pageSize == nil {
///             paginated.pageSize = defaultPageSize
///         }
///         if paginated.page == nil {
///             paginated.page = defaultPage
///         }
///         return paginated as! T
///     }
/// }
/// ```
///
/// - Note: Interceptors are synchronous and cannot perform async operations.
///   For async transformations, use middleware instead.
///
/// - SeeAlso: `Middleware`, `Pipeline`
public protocol CommandInterceptor: Sendable {
    /// Intercepts a command, optionally transforming it before pipeline execution.
    ///
    /// This method is called for every command before it enters the middleware chain.
    /// The interceptor can:
    /// - Return the command unchanged (pass-through)
    /// - Return a modified copy of the command
    /// - Return a completely different command of the same type
    ///
    /// - Parameter command: The command being executed
    /// - Returns: The (possibly transformed) command
    ///
    /// - Important: The returned command must be the same type as the input.
    ///   If you need to transform to a different command type, consider using
    ///   a different architectural approach.
    func intercept<T: Command>(_ command: T) -> T
}

/// A type-safe interceptor that only processes specific command types.
///
/// `TypedCommandInterceptor` simplifies interceptor implementation by handling
/// the type-checking boilerplate. You only implement logic for your specific
/// command type; all other commands pass through unchanged.
///
/// ## Example
///
/// ```swift
/// struct SearchQueryNormalizer: TypedCommandInterceptor {
///     typealias CommandType = SearchCommand
///
///     func intercept(_ command: SearchCommand) -> SearchCommand {
///         var normalized = command
///         normalized.query = command.query
///             .trimmingCharacters(in: .whitespaces)
///             .lowercased()
///         return normalized
///     }
/// }
/// ```
///
/// - SeeAlso: `CommandInterceptor`
public protocol TypedCommandInterceptor: CommandInterceptor {
    /// The specific command type this interceptor handles.
    associatedtype CommandType: Command

    /// Intercepts and potentially transforms a command of the specific type.
    ///
    /// - Parameter command: The command to intercept
    /// - Returns: The (possibly transformed) command
    func intercept(_ command: CommandType) -> CommandType
}

/// Default implementation that provides type-safe dispatching.
public extension TypedCommandInterceptor {
    /// Routes commands to the typed `intercept(_:)` method if they match the type.
    func intercept<T: Command>(_ command: T) -> T {
        if var typed = command as? CommandType {
            typed = intercept(typed)
            // This cast is safe because CommandType is a Command type
            return typed as! T
        }
        return command
    }
}

/// A container that manages multiple command interceptors.
///
/// `InterceptorChain` combines multiple interceptors and executes them in order.
/// It's used internally by pipelines but can also be useful for testing or
/// building custom interceptor logic.
///
/// ## Example
///
/// ```swift
/// let chain = InterceptorChain()
/// chain.addInterceptor(RequestIDInterceptor())
/// chain.addInterceptor(InputNormalizationInterceptor())
/// chain.addInterceptor(DefaultValuesInterceptor())
///
/// let normalizedCommand = chain.intercept(myCommand)
/// ```
public final class InterceptorChain: @unchecked Sendable {
    private var interceptors: [any CommandInterceptor] = []
    private let lock = NSLock()

    /// Creates an empty interceptor chain.
    public init() {}

    /// Creates an interceptor chain with the given interceptors.
    ///
    /// - Parameter interceptors: The interceptors to add, in execution order
    public init(interceptors: [any CommandInterceptor]) {
        self.interceptors = interceptors
    }

    /// Adds an interceptor to the end of the chain.
    ///
    /// - Parameter interceptor: The interceptor to add
    public func addInterceptor(_ interceptor: any CommandInterceptor) {
        lock.lock()
        defer { lock.unlock() }
        interceptors.append(interceptor)
    }

    /// Removes all interceptors of a specific type.
    ///
    /// - Parameter type: The type of interceptor to remove
    /// - Returns: The number of interceptors removed
    @discardableResult
    public func removeInterceptors<I: CommandInterceptor>(ofType type: I.Type) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let initialCount = interceptors.count
        interceptors.removeAll { $0 is I }
        return initialCount - interceptors.count
    }

    /// Removes all interceptors from the chain.
    public func clearInterceptors() {
        lock.lock()
        defer { lock.unlock() }
        interceptors.removeAll()
    }

    /// The current number of interceptors in the chain.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return interceptors.count
    }

    /// Returns whether the chain contains any interceptors.
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interceptors.isEmpty
    }

    /// Runs a command through all interceptors in the chain.
    ///
    /// - Parameter command: The command to intercept
    /// - Returns: The intercepted command after all transformations
    public func intercept<T: Command>(_ command: T) -> T {
        lock.lock()
        let currentInterceptors = interceptors
        lock.unlock()

        var result = command
        for interceptor in currentInterceptors {
            result = interceptor.intercept(result)
        }
        return result
    }
}
