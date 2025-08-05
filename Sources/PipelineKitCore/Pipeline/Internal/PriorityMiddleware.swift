import Foundation

/// A wrapper for middleware that includes priority information.
///
/// `PriorityMiddleware` associates a priority value with a middleware instance,
/// allowing middleware to be sorted and executed in priority order within a pipeline.
///
/// ## Priority Values
/// - Lower priority values execute first
/// - Default priority is typically 1000
/// - Common priority ranges:
///   - 0-999: High priority (authentication, rate limiting)
///   - 1000-1999: Normal priority (validation, transformation)
///   - 2000+: Low priority (logging, metrics)
///
/// ## Example
/// ```swift
/// let authMiddleware = PriorityMiddleware(
///     middleware: AuthenticationMiddleware(),
///     priority: 100  // High priority
/// )
///
/// let loggingMiddleware = PriorityMiddleware(
///     middleware: LoggingMiddleware(),
///     priority: 2000  // Low priority
/// )
/// ```
internal struct PriorityMiddleware: Sendable {
    /// The middleware instance to be executed.
    internal let middleware: any Middleware
    
    /// The priority value determining execution order (lower values execute first).
    internal let priority: Int
}
