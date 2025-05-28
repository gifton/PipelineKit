import Foundation

/// A builder for creating middleware with proper ordering.
internal struct MiddlewareOrderBuilder {
    private var middlewares: [(any Middleware, Int)] = []
    
    internal init() {}
    
    /// Adds middleware with a standard order.
    internal mutating func add(
        _ middleware: any Middleware,
        order: ExecutionPriority
    ) {
        middlewares.append((middleware, order.rawValue))
    }
    
    /// Adds middleware with a custom priority.
    internal mutating func add(
        _ middleware: any Middleware,
        priority: Int
    ) {
        middlewares.append((middleware, priority))
    }
    
    /// Adds middleware between two standard orders.
    internal mutating func add(
        _ middleware: any Middleware,
        between first: ExecutionPriority,
        and second: ExecutionPriority
    ) {
        let priority = ExecutionPriority.between(first, and: second)
        middlewares.append((middleware, priority))
    }
    
    /// Returns middleware sorted by priority.
    internal func build() -> [(any Middleware, Int)] {
        return middlewares.sorted { $0.1 < $1.1 }
    }
}