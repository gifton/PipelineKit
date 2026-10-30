import PipelineKitCore

/// Ordering metadata kept alongside the original middleware, without wrapping its capabilities.
struct MiddlewareEntry: Sendable {
    let middleware: any Middleware
    let effectivePriority: Int
    let insertionOrdinal: Int

    static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.effectivePriority != rhs.effectivePriority {
            return lhs.effectivePriority < rhs.effectivePriority
        }
        return lhs.insertionOrdinal < rhs.insertionOrdinal
    }
}
