import Foundation
import PipelineKitCore

/// A builder for creating middleware with proper ordering.
public struct MiddlewareOrderBuilder {
    private var middlewares: [(any Middleware, Int)] = []
    
    public init() {}
    
    /// Adds middleware with a standard order.
    public mutating func add(
        _ middleware: any Middleware,
        order: ExecutionPriority
    ) {
        middlewares.append((middleware, order.rawValue))
    }
    
    /// Adds middleware with a custom priority.
    public mutating func add(
        _ middleware: any Middleware,
        priority: Int
    ) {
        middlewares.append((middleware, priority))
    }
    
    /// Adds middleware between two standard orders.
    public mutating func add(
        _ middleware: any Middleware,
        between first: ExecutionPriority,
        and second: ExecutionPriority
    ) {
        let priority = ExecutionPriority.between(first, and: second)
        middlewares.append((middleware, priority))
    }
    
    /// Returns middleware sorted by priority.
    public func build() -> [(any Middleware, Int)] {
        return middlewares.sorted { $0.1 < $1.1 }
    }
}
