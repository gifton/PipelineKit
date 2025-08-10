import Foundation

/// Protocol for pluggable metric accumulation strategies.
///
/// Accumulators provide memory-efficient statistical aggregation
/// by storing only essential statistics rather than raw values.
///
/// ## Design Principles
/// - O(1) memory complexity regardless of sample count
/// - O(1) time complexity for recording values
/// - Immutable snapshots for thread-safe reads
/// - Value semantics for easy copying
public protocol MetricAccumulator: Sendable {
    /// The type of snapshot this accumulator produces.
    associatedtype Snapshot: Sendable

    /// Configuration for the accumulator.
    associatedtype Config: Sendable

    /// Initialize with configuration.
    init(config: Config)

    /// Record a new value.
    ///
    /// - Parameters:
    ///   - value: The metric value to record
    ///   - timestamp: When the value was recorded
    mutating func record(_ value: Double, at timestamp: Date)

    /// Get an immutable snapshot of current statistics.
    func snapshot() -> Snapshot

    /// Reset the accumulator to initial state.
    mutating func reset()

    /// The number of samples recorded.
    var count: Int { get }

    /// Whether the accumulator is empty.
    var isEmpty: Bool { get }
}

// MARK: - Default Implementations

public extension MetricAccumulator {
    /// Checks if the accumulator is empty.
    /// 
    /// We define isEmpty using count == 0 because count is a required property
    /// of the MetricAccumulator protocol and is always O(1) for our implementations.
    /// This is the standard pattern for defining isEmpty when count is readily available.
    var isEmpty: Bool {
        // swiftlint:disable:next empty_count
        count == 0
    }
}
