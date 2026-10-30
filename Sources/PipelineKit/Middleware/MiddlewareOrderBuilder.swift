import Foundation
import PipelineKitCore

/// A builder for creating middleware with proper ordering.
public struct MiddlewareOrderBuilder {
    private var entries: [MiddlewareEntry] = []
    
    public init() {}
    
    /// Adds middleware with a standard order.
    public mutating func add(
        _ middleware: any Middleware,
        order: ExecutionPriority
    ) {
        add(middleware, priority: order.rawValue)
    }
    
    /// Adds middleware with a custom priority.
    public mutating func add(
        _ middleware: any Middleware,
        priority: Int
    ) {
        entries.append(MiddlewareEntry(
            middleware: middleware,
            effectivePriority: priority,
            insertionOrdinal: entries.count
        ))
    }
    
    /// Adds middleware between two standard orders.
    public mutating func add(
        _ middleware: any Middleware,
        between first: ExecutionPriority,
        and second: ExecutionPriority
    ) {
        let priority = ExecutionPriority.between(first, and: second)
        add(middleware, priority: priority)
    }
    
    /// Returns middleware sorted by priority, preserving insertion order for ties.
    public func build() -> [(any Middleware, Int)] {
        entries.sorted(by: MiddlewareEntry.isOrderedBefore)
            .map { ($0.middleware, $0.effectivePriority) }
    }
}
