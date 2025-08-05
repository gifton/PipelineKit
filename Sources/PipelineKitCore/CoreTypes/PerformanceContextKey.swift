import Foundation

/// Context key for storing performance measurements.
/// 
/// This key is used by performance monitoring middleware to store
/// measurement data in the command context for later retrieval.
///
/// ## Design Decision: Type-Erased Performance Data
///
/// This key uses a type-erased wrapper instead of Any to maintain Sendable conformance
/// while avoiding a dependency on the Observability module from Core.
public struct PerformanceMeasurementKey: ContextKey {
    public typealias Value = PerformanceData
}

/// Type-erased wrapper for performance measurement data.
///
/// This wrapper allows Core to store performance data without depending on
/// the Observability module's PerformanceMeasurement type.
///
/// ## Design Decision: @unchecked Sendable for Type-Erased Storage
///
/// This struct uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Module Dependency**: Core cannot depend on Observability, so we cannot reference
///    PerformanceMeasurement directly. This requires type erasure via Any.
///
/// 2. **Generic Constraint**: The init method constrains T to Sendable, ensuring only
///    thread-safe types can be stored. This provides compile-time safety at the API boundary.
///
/// 3. **Immutable Storage**: The data property is immutable (let), preventing any mutations
///    after initialization that could cause thread safety issues.
///
/// 4. **Known Usage Pattern**: This is only used to store PerformanceMeasurement instances
///    from the Observability module, which are already Sendable.
///
/// This is a necessary pattern for cross-module type erasure where direct type references
/// would create circular dependencies.
///
/// Thread Safety: This type is thread-safe because it only contains immutable data.
/// The generic init constraint ensures only Sendable types can be stored.
/// Invariant: The data property is immutable (let) and can only be set during initialization
/// with a Sendable-constrained type, ensuring thread safety throughout the object's lifetime.
public struct PerformanceData: @unchecked Sendable {
    /// The actual performance measurement data
    private let data: Any
    
    /// Creates a new performance data wrapper
    public init<T: Sendable>(_ measurement: T) {
        self.data = measurement
    }
    
    /// Attempts to retrieve the wrapped data as a specific type
    public func get<T>() -> T? {
        data as? T
    }
}
