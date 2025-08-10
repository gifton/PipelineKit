import Foundation
import Atomics
import PipelineKitCore

/// A high-performance metric with atomic storage for lock-free operations.
///
/// AtomicMetric provides the same API as regular Metric but with
/// thread-safe atomic operations that have minimal overhead (~10ns).
/// Use atomic metrics for high-frequency counters and gauges.
public actor AtomicMetric<Kind: MetricKind> {
    /// The metric name.
    public let name: MetricName

    /// The metric tags.
    public let tags: MetricTags

    /// The metric unit (optional).
    public let unit: MetricUnit?

    /// The internal atomic storage.
    private let storage: any MetricStorage

    /// Initialize with atomic counter storage.
    public init(name: MetricName, storage: AtomicCounterStorage, tags: MetricTags = [:]) where Kind == Counter {
        self.name = name
        self.storage = storage
        self.tags = tags
        self.unit = .count
    }

    /// Initialize with atomic gauge storage.
    public init(name: MetricName, storage: AtomicGaugeStorage, unit: MetricUnit? = nil, tags: MetricTags = [:]) where Kind == Gauge {
        self.name = name
        self.storage = storage
        self.tags = tags
        self.unit = unit
    }

    /// Get the current value.
    public var value: Double {
        switch storage {
        case let s as AtomicCounterStorage:
            return s.load()
        case let s as AtomicGaugeStorage:
            return s.load()
        case let s as ValueStorage<Double>:
            return s.load()
        default:
            return 0
        }
    }

    /// Create a snapshot of the current state.
    public func snapshot() -> MetricSnapshot {
        MetricSnapshot(
            name: name.fullName,
            type: Kind.type.rawValue,
            value: value,
            timestamp: Date(),
            tags: tags,
            unit: unit?.rawValue
        )
    }

    /// Create a regular (non-atomic) metric from the current state.
    public func toMetric() -> Metric<Kind> {
        Metric<Kind>(
            name: name,
            value: MetricValue(value, unit: unit),
            timestamp: Date(),
            tags: tags
        )
    }
}

// MARK: - Counter Operations

public extension AtomicMetric where Kind == Counter {
    /// Atomically increment the counter.
    ///
    /// This operation is lock-free and thread-safe with ~10ns overhead.
    ///
    /// - Parameter amount: The amount to increment
    /// - Returns: The new value after increment
    @discardableResult
    func increment(by amount: Double = 1.0) -> Double {
        guard let counterStorage = storage as? AtomicCounterStorage else {
            return 0
        }
        return counterStorage.increment(by: amount)
    }

    /// Atomically decrement the counter.
    ///
    /// Note: Use carefully as counters are typically monotonic.
    ///
    /// - Parameter amount: The amount to decrement
    /// - Returns: The new value after decrement
    @discardableResult
    func decrement(by amount: Double = 1.0) -> Double {
        guard let counterStorage = storage as? AtomicCounterStorage else {
            return 0
        }
        return counterStorage.increment(by: -amount)
    }

    /// Reset the counter to zero.
    func reset() {
        guard let counterStorage = storage as? AtomicCounterStorage else {
            return
        }
        counterStorage.store(0)
    }

    /// Get the current value and reset to zero atomically.
    ///
    /// - Returns: The value before reset
    func getAndReset() -> Double {
        guard let counterStorage = storage as? AtomicCounterStorage else {
            return 0
        }
        return counterStorage.exchange(0)
    }
}

// MARK: - Gauge Operations

public extension AtomicMetric where Kind == Gauge {
    /// Atomically set the gauge to a specific value.
    ///
    /// - Parameter newValue: The new value
    func set(to newValue: Double) {
        guard let gaugeStorage = storage as? AtomicGaugeStorage else {
            return
        }
        gaugeStorage.store(newValue)
    }

    /// Atomically adjust the gauge by a delta.
    ///
    /// - Parameter delta: The amount to adjust (can be negative)
    /// - Returns: The new value after adjustment
    @discardableResult
    func adjust(by delta: Double) -> Double {
        guard let gaugeStorage = storage as? AtomicGaugeStorage else {
            return 0
        }
        return gaugeStorage.increment(by: delta)
    }

    /// Atomically compare and set the gauge value.
    ///
    /// This operation will only update the gauge if the current value
    /// matches the expected value, useful for lock-free algorithms.
    ///
    /// - Parameters:
    ///   - expected: The expected current value
    ///   - newValue: The new value to set
    /// - Returns: True if the value was updated, false otherwise
    @discardableResult
    func compareAndSet(expecting expected: Double, newValue: Double) -> Bool {
        guard let gaugeStorage = storage as? AtomicGaugeStorage else {
            return false
        }
        return gaugeStorage.compareExchange(expected: expected, desired: newValue)
    }

    /// Get the current value and set a new one atomically.
    ///
    /// - Parameter newValue: The new value to set
    /// - Returns: The previous value
    func getAndSet(_ newValue: Double) -> Double {
        guard let gaugeStorage = storage as? AtomicGaugeStorage else {
            return 0
        }
        return gaugeStorage.exchange(newValue)
    }

    /// Atomically update the gauge using a closure.
    ///
    /// The closure may be called multiple times if there's contention.
    ///
    /// - Parameter transform: A closure that transforms the current value
    /// - Returns: The new value after transformation
    @discardableResult
    func update(_ transform: (Double) -> Double) -> Double {
        guard let gaugeStorage = storage as? AtomicGaugeStorage else {
            return 0
        }

        while true {
            let current = gaugeStorage.load()
            let new = transform(current)
            if gaugeStorage.compareExchange(expected: current, desired: new) {
                return new
            }
            // Retry if another thread modified the value
        }
    }
}

// MARK: - Common Operations

public extension AtomicMetric where Kind == Counter {
    /// Add tags to the metric.
    ///
    /// Note: This creates a new AtomicMetric with the same storage.
    ///
    /// - Parameter newTags: Tags to add
    /// - Returns: A new metric with merged tags
    func with(tags newTags: MetricTags) -> AtomicMetric<Counter> {
        var mergedTags = self.tags
        for (key, value) in newTags {
            mergedTags[key] = value
        }

        guard let counterStorage = storage as? AtomicCounterStorage else {
            fatalError("Storage type mismatch: expected AtomicCounterStorage")
        }

        return AtomicMetric(
            name: name,
            storage: counterStorage,
            tags: mergedTags
        )
    }
}

public extension AtomicMetric where Kind == Gauge {
    /// Add tags to the metric.
    ///
    /// Note: This creates a new AtomicMetric with the same storage.
    ///
    /// - Parameter newTags: Tags to add
    /// - Returns: A new metric with merged tags
    func with(tags newTags: MetricTags) -> AtomicMetric<Gauge> {
        var mergedTags = self.tags
        for (key, value) in newTags {
            mergedTags[key] = value
        }

        guard let gaugeStorage = storage as? AtomicGaugeStorage else {
            fatalError("Storage type mismatch: expected AtomicGaugeStorage")
        }

        return AtomicMetric(
            name: name,
            storage: gaugeStorage,
            unit: unit,
            tags: mergedTags
        )
    }
}

// MARK: - Conversion

public extension Collection {
    /// Convert atomic metrics to snapshots for export.
    func toSnapshots<K: MetricKind>() async -> [MetricSnapshot] where Element == AtomicMetric<K> {
        await withTaskGroup(of: MetricSnapshot.self) { group in
            for metric in self {
                group.addTask {
                    await metric.snapshot()
                }
            }

            var snapshots: [MetricSnapshot] = []
            for await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots
        }
    }
}
