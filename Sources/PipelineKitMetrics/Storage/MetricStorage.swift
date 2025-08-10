import Foundation
import Atomics

/// Protocol defining storage strategies for metrics.
///
/// This allows for different storage implementations ranging from
/// simple value semantics to high-performance atomic operations.
protocol MetricStorage: Sendable {
    associatedtype Value

    /// Load the current value.
    func load() -> Value

    /// Store a new value.
    func store(_ value: Value)

    /// Exchange the current value with a new one, returning the old value.
    func exchange(_ value: Value) -> Value
}

/// Protocol for storage that supports atomic increment operations.
protocol IncrementableStorage: MetricStorage where Value: AdditiveArithmetic {
    /// Atomically increment the value by the given delta.
    func increment(by delta: Value) -> Value
}

/// Protocol for storage that supports compare-and-set operations.
protocol ComparableStorage: MetricStorage where Value: Equatable {
    /// Atomically set the value only if it matches the expected value.
    ///
    /// - Parameters:
    ///   - expected: The expected current value
    ///   - desired: The new value to set
    /// - Returns: True if the value was updated, false otherwise
    func compareExchange(expected: Value, desired: Value) -> Bool
}

// MARK: - Atomic Counter Storage

/// High-performance atomic storage for counter metrics.
///
/// Uses lock-free atomic operations for thread-safe increments
/// with minimal overhead (~10ns per operation).
///
/// Thread Safety: This type is thread-safe through the use of ManagedAtomic<UInt64>
/// which provides lock-free atomic operations. All operations use appropriate memory
/// ordering to ensure visibility across threads.
/// Invariant: The stored value must always be a valid finite floating-point number.
/// Non-finite values (NaN, Infinity) are sanitized to 0. The bit pattern conversion
/// preserves all valid Double values exactly.
public final class AtomicCounterStorage: @unchecked Sendable {
    private let atomic: ManagedAtomic<UInt64>

    public init(initialValue: Double = 0) {
        self.atomic = ManagedAtomic(Self.doubleToUInt64(Self.sanitize(initialValue)))
    }

    deinit {
        // ManagedAtomic cleanup happens automatically
    }

    private static func doubleToUInt64(_ value: Double) -> UInt64 {
        value.bitPattern
    }

    private static func uint64ToDouble(_ value: UInt64) -> Double {
        Double(bitPattern: value)
    }

    private static func sanitize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return value
    }
}

extension AtomicCounterStorage: MetricStorage {
    typealias Value = Double

    func load() -> Double {
        Self.uint64ToDouble(atomic.load(ordering: .acquiring))
    }

    func store(_ value: Double) {
        atomic.store(Self.doubleToUInt64(Self.sanitize(value)), ordering: .releasing)
    }

    func exchange(_ value: Double) -> Double {
        Self.uint64ToDouble(atomic.exchange(Self.doubleToUInt64(Self.sanitize(value)), ordering: .acquiringAndReleasing))
    }
}

extension AtomicCounterStorage: IncrementableStorage {
    func increment(by delta: Double) -> Double {
        // Use CAS loop to preserve floating-point precision
        let sanitizedDelta = Self.sanitize(delta)
        while true {
            let current = load()
            let new = Self.sanitize(current + sanitizedDelta)
            if compareExchange(expected: current, desired: new) {
                return new
            }
            // Retry if another thread modified the value
        }
    }
}

extension AtomicCounterStorage: ComparableStorage {
    func compareExchange(expected: Double, desired: Double) -> Bool {
        let expectedBits = Self.doubleToUInt64(expected)
        let desiredBits = Self.doubleToUInt64(Self.sanitize(desired))

        let (exchanged, _) = atomic.compareExchange(
            expected: expectedBits,
            desired: desiredBits,
            ordering: .acquiringAndReleasing
        )

        return exchanged
    }
}

// MARK: - Atomic Gauge Storage

/// High-performance atomic storage for gauge metrics.
///
/// Supports both atomic updates and compare-and-set operations
/// for lock-free gauge modifications.
///
/// Thread Safety: This type is thread-safe through the use of ManagedAtomic<UInt64>
/// which provides lock-free atomic operations. All operations use appropriate memory
/// ordering to ensure visibility across threads.
/// Invariant: The stored value must always be a valid finite floating-point number.
/// Non-finite values (NaN, Infinity) are sanitized to 0. The bit pattern conversion
/// preserves all valid Double values exactly.
public final class AtomicGaugeStorage: @unchecked Sendable {
    private let atomic: ManagedAtomic<UInt64>

    public init(initialValue: Double = 0) {
        self.atomic = ManagedAtomic(Self.doubleToUInt64(Self.sanitize(initialValue)))
    }

    deinit {
        // ManagedAtomic cleanup happens automatically
    }

    private static func doubleToUInt64(_ value: Double) -> UInt64 {
        value.bitPattern
    }

    private static func uint64ToDouble(_ value: UInt64) -> Double {
        Double(bitPattern: value)
    }

    private static func sanitize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return value
    }
}

extension AtomicGaugeStorage: MetricStorage {
    typealias Value = Double

    func load() -> Double {
        Self.uint64ToDouble(atomic.load(ordering: .acquiring))
    }

    func store(_ value: Double) {
        atomic.store(Self.doubleToUInt64(Self.sanitize(value)), ordering: .releasing)
    }

    func exchange(_ value: Double) -> Double {
        Self.uint64ToDouble(atomic.exchange(Self.doubleToUInt64(Self.sanitize(value)), ordering: .acquiringAndReleasing))
    }
}

extension AtomicGaugeStorage: ComparableStorage {
    func compareExchange(expected: Double, desired: Double) -> Bool {
        let expectedBits = Self.doubleToUInt64(expected)
        let desiredBits = Self.doubleToUInt64(Self.sanitize(desired))

        let (exchanged, _) = atomic.compareExchange(
            expected: expectedBits,
            desired: desiredBits,
            ordering: .acquiringAndReleasing
        )

        return exchanged
    }
}

extension AtomicGaugeStorage: IncrementableStorage {
    func increment(by delta: Double) -> Double {
        // For gauges, we need to load, add, and compare-exchange in a loop
        while true {
            let current = load()
            let new = Self.sanitize(current + delta)
            if compareExchange(expected: current, desired: new) {
                return new
            }
            // Retry if another thread modified the value
        }
    }
}

// MARK: - Value Storage

/// Simple value-based storage for metrics that don't need atomic operations.
///
/// This provides the same interface but with basic value semantics,
/// suitable for low-frequency metrics or when atomicity isn't required.
///
/// Thread Safety: This type is thread-safe through the use of NSLock which provides
/// mutual exclusion for all operations. The generic type T is constrained to Sendable
/// to ensure the stored values are safe to share across threads.
/// Invariant: All access to the stored value must be protected by the lock. The lock
/// must be acquired before reading or writing the value and released immediately after.
final class ValueStorage<T: Sendable>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(initialValue: T) {
        self.value = initialValue
    }
}

extension ValueStorage: MetricStorage {
    typealias Value = T

    func load() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func exchange(_ newValue: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}

extension ValueStorage: IncrementableStorage where T: AdditiveArithmetic {
    func increment(by delta: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        value += delta
        return value
    }
}

extension ValueStorage: ComparableStorage where T: Equatable {
    func compareExchange(expected: T, desired: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if value == expected {
            value = desired
            return true
        }
        return false
    }
}

// MARK: - Storage Factory

/// Factory for creating appropriate storage based on requirements.
enum MetricStorageFactory {
    /// Create atomic storage for high-frequency counters.
    static func atomicCounter(initialValue: Double = 0) -> AtomicCounterStorage {
        AtomicCounterStorage(initialValue: initialValue)
    }

    /// Create atomic storage for high-frequency gauges.
    static func atomicGauge(initialValue: Double = 0) -> AtomicGaugeStorage {
        AtomicGaugeStorage(initialValue: initialValue)
    }

    /// Create value storage for low-frequency metrics.
    static func value<T: Sendable>(initialValue: T) -> ValueStorage<T> {
        ValueStorage(initialValue: initialValue)
    }
}
