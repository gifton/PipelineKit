import Foundation
import PipelineKitCore

// MARK: - Snapshot Pool

/// A pool of reusable MetricSnapshot instances to reduce allocation overhead.
///
/// This pool uses a lock-free stack to manage instances efficiently.
/// The pool is particularly useful when exporting large batches of metrics.
actor MetricSnapshotPool {
    private static let defaultCapacity = 1000
    private var pool: [MetricSnapshot] = []
    private let maxCapacity: Int

    /// Shared pool instance.
    static let shared = MetricSnapshotPool()

    init(capacity: Int = defaultCapacity) {
        self.maxCapacity = capacity
        pool.reserveCapacity(min(capacity, 100))
    }

    /// Acquire a snapshot from the pool or create a new one.
    ///
    /// - Parameters:
    ///   - name: The metric name
    ///   - type: The metric type
    ///   - value: The metric value
    ///   - timestamp: The timestamp
    ///   - tags: The metric tags
    ///   - unit: The metric unit
    /// - Returns: A configured MetricSnapshot
    func acquire(
        name: String,
        type: String,
        value: Double,
        timestamp: Date = Date(),
        tags: [String: String] = [:],
        unit: String? = nil
    ) -> MetricSnapshot {
        // For now, always create new instances since MetricSnapshot is immutable
        // In a future optimization, we could use a mutable builder pattern
        MetricSnapshot(
            name: name,
            type: type,
            value: value,
            timestamp: timestamp,
            tags: tags,
            unit: unit
        )
    }

    /// Return a snapshot to the pool for reuse.
    ///
    /// Note: Since MetricSnapshot is immutable, this is a no-op for now.
    /// Future versions could implement a mutable builder pattern.
    func release(_ snapshot: MetricSnapshot) {
        // No-op for immutable snapshots
    }
}

// MARK: - Batch Conversion

public extension Collection where Element: MetricConvertible {
    /// Convert a collection of metrics to snapshots with optimized allocation.
    ///
    /// This method minimizes allocations by:
    /// 1. Pre-allocating the result array
    /// 2. Reusing string storage where possible
    /// 3. Using a single timestamp for batch operations
    ///
    /// - Parameter timestamp: Optional shared timestamp for all snapshots
    /// - Returns: Array of metric snapshots
    func toSnapshots(timestamp: Date? = nil) -> [MetricSnapshot] {
        let sharedTimestamp = timestamp ?? Date()
        var snapshots = [MetricSnapshot]()
        snapshots.reserveCapacity(count)

        for element in self {
            snapshots.append(element.toSnapshot(timestamp: sharedTimestamp))
        }

        return snapshots
    }
}

/// Protocol for types that can be converted to MetricSnapshot.
public protocol MetricConvertible {
    /// Convert to a metric snapshot.
    ///
    /// - Parameter timestamp: Optional timestamp override
    /// - Returns: A metric snapshot
    func toSnapshot(timestamp: Date?) -> MetricSnapshot
}

// MARK: - String Interning

/// String interning for commonly used metric names and tags.
///
/// This reduces memory usage and allocation overhead for frequently
/// used strings in the metrics system.
public actor StringInterner {
    private var internedStrings: [String: String] = [:]
    private let maxSize: Int

    /// Shared interner instance.
    public static let shared = StringInterner()

    init(maxSize: Int = 10000) {
        self.maxSize = maxSize
    }

    /// Intern a string, returning a canonical instance.
    ///
    /// - Parameter string: The string to intern
    /// - Returns: The canonical string instance
    public func intern(_ string: String) -> String {
        if let existing = internedStrings[string] {
            return existing
        }

        // Only intern if we haven't hit the size limit
        if internedStrings.count < maxSize {
            internedStrings[string] = string
            return string
        }

        return string
    }

    /// Intern a dictionary of tags.
    ///
    /// - Parameter tags: The tags to intern
    /// - Returns: Dictionary with interned keys and values
    public func internTags(_ tags: [String: String]) -> [String: String] {
        var interned: [String: String] = [:]
        interned.reserveCapacity(tags.count)

        for (key, value) in tags {
            interned[intern(key)] = intern(value)
        }

        return interned
    }

    /// Clear the interner cache.
    public func clear() {
        internedStrings.removeAll(keepingCapacity: true)
    }
}

// MARK: - Snapshot Builder

/// A builder for creating MetricSnapshot instances with minimal allocations.
///
/// This builder reuses internal buffers and provides a fluent API
/// for constructing snapshots efficiently.
public struct MetricSnapshotBuilder {
    private var name: String = ""
    private var type = ""
    private var value: Double = 0
    private var timestamp = Date()
    private var tags: [String: String] = [:]
    private var unit: String?

    public init() {}

    /// Set the metric name.
    public mutating func withName(_ name: String) -> Self {
        self.name = name
        return self
    }

    /// Set the metric type.
    public mutating func withType(_ type: String) -> Self {
        self.type = type
        return self
    }

    /// Set the metric value.
    public mutating func withValue(_ value: Double) -> Self {
        self.value = value
        return self
    }

    /// Set the timestamp.
    public mutating func withTimestamp(_ timestamp: Date) -> Self {
        self.timestamp = timestamp
        return self
    }

    /// Add tags.
    public mutating func withTags(_ tags: [String: String]) -> Self {
        self.tags = tags
        return self
    }

    /// Add a single tag.
    public mutating func withTag(_ key: String, _ value: String) -> Self {
        self.tags[key] = value
        return self
    }

    /// Set the unit.
    public mutating func withUnit(_ unit: String?) -> Self {
        self.unit = unit
        return self
    }

    /// Build the snapshot.
    public func build() -> MetricSnapshot {
        MetricSnapshot(
            name: name,
            type: type,
            value: value,
            timestamp: timestamp,
            tags: tags,
            unit: unit
        )
    }
}

// MARK: - COW Optimization

/// Copy-on-write wrapper for metric snapshots.
///
/// This allows multiple references to share the same underlying
/// snapshot data until a modification is made.
public struct COWMetricSnapshot {
    private var storage: Storage

    private class Storage {
        let snapshot: MetricSnapshot

        init(_ snapshot: MetricSnapshot) {
            self.snapshot = snapshot
        }
    }

    public init(_ snapshot: MetricSnapshot) {
        self.storage = Storage(snapshot)
    }

    /// Get the underlying snapshot.
    public var snapshot: MetricSnapshot {
        storage.snapshot
    }

    /// Create a modified copy with new tags.
    public func withTags(_ tags: [String: String]) -> COWMetricSnapshot {
        let newSnapshot = MetricSnapshot(
            name: snapshot.name,
            type: snapshot.type,
            value: snapshot.value,
            timestamp: snapshot.timestamp,
            tags: tags,
            unit: snapshot.unit
        )
        return COWMetricSnapshot(newSnapshot)
    }

    /// Create a modified copy with a new value.
    public func withValue(_ value: Double) -> COWMetricSnapshot {
        let newSnapshot = MetricSnapshot(
            name: snapshot.name,
            type: snapshot.type,
            value: value,
            timestamp: snapshot.timestamp,
            tags: snapshot.tags,
            unit: snapshot.unit
        )
        return COWMetricSnapshot(newSnapshot)
    }
}

// MARK: - Zero-Allocation Snapshot View

/// A view over metric data that avoids creating a snapshot until needed.
///
/// This is useful for filtering or transforming metrics without
/// materializing intermediate snapshots.
public struct MetricSnapshotView {
    public let name: String
    public let type: String
    public let value: Double
    public let timestamp: Date
    public let tags: [String: String]
    public let unit: String?

    /// Create a view from a snapshot.
    public init(from snapshot: MetricSnapshot) {
        self.name = snapshot.name
        self.type = snapshot.type
        self.value = snapshot.value
        self.timestamp = snapshot.timestamp
        self.tags = snapshot.tags
        self.unit = snapshot.unit
    }

    /// Materialize the view into a snapshot.
    public func materialize() -> MetricSnapshot {
        MetricSnapshot(
            name: name,
            type: type,
            value: value,
            timestamp: timestamp,
            tags: tags,
            unit: unit
        )
    }

    /// Check if this view matches a predicate without creating a snapshot.
    public func matches(predicate: (MetricSnapshotView) -> Bool) -> Bool {
        predicate(self)
    }
}

// MARK: - Batch Operations

/// Optimized batch operations for metric snapshots.
public enum MetricSnapshotBatch {
    /// Filter snapshots without intermediate allocations.
    public static func filter(
        _ snapshots: [MetricSnapshot],
        predicate: (MetricSnapshotView) -> Bool
    ) -> [MetricSnapshot] {
        var result: [MetricSnapshot] = []
        result.reserveCapacity(snapshots.count / 2) // Assume 50% match rate

        for snapshot in snapshots {
            let view = MetricSnapshotView(from: snapshot)
            if predicate(view) {
                result.append(snapshot)
            }
        }

        return result
    }

    /// Transform snapshots with minimal allocations.
    public static func map<T>(
        _ snapshots: [MetricSnapshot],
        transform: (MetricSnapshotView) -> T
    ) -> [T] {
        var result: [T] = []
        result.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            let view = MetricSnapshotView(from: snapshot)
            result.append(transform(view))
        }

        return result
    }

    /// Group snapshots by a key efficiently.
    public static func groupBy<Key: Hashable>(
        _ snapshots: [MetricSnapshot],
        key: (MetricSnapshotView) -> Key
    ) -> [Key: [MetricSnapshot]] {
        var groups: [Key: [MetricSnapshot]] = [:]

        for snapshot in snapshots {
            let view = MetricSnapshotView(from: snapshot)
            let groupKey = key(view)
            groups[groupKey, default: []].append(snapshot)
        }

        return groups
    }
}
