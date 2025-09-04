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
    
    /// Returns middleware sorted by priority, preserving insertion order for ties.
    public func build() -> [(any Middleware, Int)] {
        return middlewares
            .enumerated()
            .sorted { lhs, rhs in
                let lp = lhs.element.1
                let rp = rhs.element.1
                if lp != rp { return lp < rp }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }
}
