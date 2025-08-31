import Foundation

/// Type-safe key for CommandContext storage.
///
/// ContextKey provides compile-time type safety for values stored in CommandContext.
/// Each key is associated with a specific value type, preventing type mismatches.
///
/// ## Usage Example
/// ```swift
/// // Define a key
/// let userIDKey = ContextKey<String>("userID")
/// 
/// // Use with CommandContext
/// context[userIDKey] = "user123"
/// let id: String? = context[userIDKey]  // Type-safe access
/// ```
@frozen
public struct ContextKey<Value: Sendable>: Hashable, Sendable {
    /// The string name of the key
    public let name: String

    /// Creates a new context key with the specified name.
    /// - Parameter name: The unique name for this key
    @inlinable
    public init(_ name: String) {
        self.name = name
    }
}

// MARK: - Standard Keys

/// Namespace for predefined context keys
public enum ContextKeys {
    // MARK: Request Metadata

    /// Key for request ID
    public static let requestID = ContextKey<String>("requestID")

    /// Key for user ID
    public static let userID = ContextKey<String>("userID")

    /// Key for correlation ID
    public static let correlationID = ContextKey<String>("correlationID")

    /// Key for start time
    public static let startTime = ContextKey<Date>("startTime")

    /// Key for metrics dictionary
    public static let metrics = ContextKey<[String: any Sendable]>("metrics")

    /// Key for metadata dictionary
    public static let metadata = ContextKey<[String: any Sendable]>("metadata")

    /// Key for trace ID (for distributed tracing)
    public static let traceID = ContextKey<String>("traceID")

    /// Key for span ID (for distributed tracing)
    public static let spanID = ContextKey<String>("spanID")

    /// Key for command type name
    public static let commandType = ContextKey<String>("commandType")

    /// Key for command ID
    public static let commandID = ContextKey<UUID>("commandID")

    // MARK: Security

    /// Key for authentication token
    public static let authToken = ContextKey<String>("authToken")

    /// Key for authenticated user info
    public static let authenticatedUser = ContextKey<[String: any Sendable]>("authenticatedUser")

    /// Key for authorization roles
    public static let roles = ContextKey<[String]>("roles")

    /// Key for permissions
    public static let permissions = ContextKey<[String]>("permissions")

    // MARK: Observability

    /// Key for log level
    public static let logLevel = ContextKey<String>("logLevel")

    /// Key for log context
    public static let logContext = ContextKey<[String: any Sendable]>("logContext")

    /// Key for performance measurements
    public static let performanceMeasurements = ContextKey<[String: TimeInterval]>("performanceMeasurements")

    // MARK: Resilience

    /// Key for retry count
    public static let retryCount = ContextKey<Int>("retryCount")

    /// Key for circuit breaker state
    public static let circuitBreakerState = ContextKey<String>("circuitBreakerState")

    /// Key for rate limit remaining
    public static let rateLimitRemaining = ContextKey<Int>("rateLimitRemaining")
    
    /// Key for cancellation reason
    public static let cancellationReason = ContextKey<CancellationReason>("cancellationReason")
}

// MARK: - Convenience Factory Methods

public extension ContextKey {
    /// Creates a custom key with automatic type inference.
    /// 
    /// Example:
    /// ```swift
    /// let temperatureKey = ContextKey.custom("temperature", Double.self)
    /// context[temperatureKey] = 98.6
    /// ```
    @inlinable
    static func custom<T: Sendable>(_ name: String, _ type: T.Type) -> ContextKey<T> {
        ContextKey<T>(name)
    }
}
