import Foundation

/// Protocol for middleware that has a recommended execution priority.
/// 
/// Middleware implementing this protocol provides a recommended
/// `ExecutionPriority` to ensure proper execution sequence in the pipeline.
/// 
/// Example:
/// ```swift
/// struct MyMiddleware: Middleware, PrioritizedMiddleware {
///     static var recommendedOrder: ExecutionPriority { .validation }
///     
///     func execute<T: Command>(...) async throws -> T.Result {
///         // Implementation
///     }
/// }
/// ```
public protocol PrioritizedMiddleware: Middleware {
    /// The recommended execution priority for this middleware
    static var recommendedOrder: ExecutionPriority { get }
}