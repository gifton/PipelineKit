import Foundation

/// A type-safe key for storing values in a command context.
/// 
/// Context keys provide type safety when storing and retrieving values
/// from the command execution context.
/// 
/// Example:
/// ```swift
/// struct UserContextKey: ContextKey {
///     typealias Value = User
/// }
/// 
/// // Store in context
/// context[UserContextKey.self] = authenticatedUser
/// 
/// // Retrieve from context
/// let user = context[UserContextKey.self]
/// ```
public protocol ContextKey {
    /// The type of value associated with this key
    associatedtype Value: Sendable
}

/// A context that carries data throughout command execution.
/// 
/// The command context provides a type-safe way to share data between
/// middleware components and handlers during command execution. It's
/// particularly useful for:
/// 
/// - Authentication/authorization results
/// - Request timing and performance metrics
/// - Feature flags and configuration
/// - Temporary computation results
/// - Cross-cutting concerns
/// 
/// The context is request-scoped and isolated to a single command execution.
public actor CommandContext {
    private var storage: [ObjectIdentifier: Any] = [:]
    private let metadata: CommandMetadata
    
    /// Creates a new command context with the given metadata.
    /// 
    /// - Parameter metadata: The command metadata for this execution
    public init(metadata: CommandMetadata) {
        self.metadata = metadata
    }
    
    /// Gets the command metadata.
    public var commandMetadata: CommandMetadata {
        metadata
    }
    
    /// Gets a value from the context using a type-safe key.
    /// 
    /// - Parameter key: The context key type
    /// - Returns: The stored value, or nil if not present
    public subscript<Key: ContextKey>(_ key: Key.Type) -> Key.Value? {
        get {
            storage[ObjectIdentifier(key)] as? Key.Value
        }
    }
    
    /// Sets a value in the context using a type-safe key.
    /// 
    /// - Parameters:
    ///   - key: The context key type
    ///   - value: The value to store
    public func set<Key: ContextKey>(_ value: Key.Value?, for key: Key.Type) {
        if let value = value {
            storage[ObjectIdentifier(key)] = value
        } else {
            storage.removeValue(forKey: ObjectIdentifier(key))
        }
    }
    
    /// Removes a value from the context.
    /// 
    /// - Parameter key: The context key type
    public func remove<Key: ContextKey>(_ key: Key.Type) {
        storage.removeValue(forKey: ObjectIdentifier(key))
    }
    
    /// Clears all values from the context.
    public func clear() {
        storage.removeAll()
    }
    
    /// Gets all keys currently stored in the context.
    public var keys: [ObjectIdentifier] {
        Array(storage.keys)
    }
}

/// Protocol for middleware that uses context.
/// 
/// Context-aware middleware can read and write to the command context,
/// allowing data sharing between middleware components.
public protocol ContextAwareMiddleware: Sendable {
    /// Executes the middleware with context access.
    /// 
    /// - Parameters:
    ///   - command: The command being processed
    ///   - context: The command execution context
    ///   - next: The next handler in the chain
    /// - Returns: The result from executing the command
    /// - Throws: Any errors that occur during execution
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}

/// Adapter that allows regular middleware to work in a context-aware pipeline.
public struct ContextMiddlewareAdapter: ContextAwareMiddleware {
    private let middleware: any Middleware
    
    public init(_ middleware: any Middleware) {
        self.middleware = middleware
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Create a wrapper that provides the old interface
        let nextWrapper: @Sendable (T, CommandMetadata) async throws -> T.Result = { cmd, metadata in
            try await next(cmd, context)
        }
        
        return try await middleware.execute(
            command,
            metadata: await context.commandMetadata,
            next: nextWrapper
        )
    }
}

// MARK: - Common Context Keys

/// Context key for storing authenticated user information.
public struct AuthenticatedUserKey: ContextKey {
    public typealias Value = String // User ID
}

/// Context key for storing request start time.
public struct RequestStartTimeKey: ContextKey {
    public typealias Value = Date
}

/// Context key for storing request ID for tracing.
public struct RequestIDKey: ContextKey {
    public typealias Value = String
}

/// Context key for storing feature flags.
public struct FeatureFlagsKey: ContextKey {
    public typealias Value = Set<String>
}

/// Context key for storing authorization roles.
public struct AuthorizationRolesKey: ContextKey {
    public typealias Value = Set<String>
}