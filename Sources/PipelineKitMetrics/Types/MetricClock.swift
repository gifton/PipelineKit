import Foundation

// MARK: - Clock Protocol

/// Protocol for providing time information to the metrics system.
///
/// This abstraction allows for deterministic testing and custom time sources.
public protocol MetricClock: Sendable {
    /// Get the current time.
    func now() -> Date

    /// Get the current time interval since reference date.
    func timeIntervalSinceReferenceDate() -> TimeInterval

    /// Get the current time interval since 1970.
    func timeIntervalSince1970() -> TimeInterval

    /// Measure the duration of an operation.
    ///
    /// - Parameter operation: The operation to measure
    /// - Returns: The duration in seconds
    func measure<T: Sendable>(_ operation: @Sendable () throws -> T) rethrows -> (result: T, duration: TimeInterval)

    /// Measure the duration of an async operation.
    ///
    /// - Parameter operation: The async operation to measure
    /// - Returns: The duration in seconds
    func measure<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> (result: T, duration: TimeInterval)
}

// MARK: - System Clock

/// The default system clock that uses the system time.
public struct SystemClock: MetricClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func timeIntervalSinceReferenceDate() -> TimeInterval {
        Date.timeIntervalSinceReferenceDate
    }

    public func timeIntervalSince1970() -> TimeInterval {
        Date().timeIntervalSince1970
    }

    public func measure<T: Sendable>(_ operation: @Sendable () throws -> T) rethrows -> (result: T, duration: TimeInterval) {
        let start = Date()
        let result = try operation()
        let duration = Date().timeIntervalSince(start)
        return (result, duration)
    }

    public func measure<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> (result: T, duration: TimeInterval) {
        let start = Date()
        let result = try await operation()
        let duration = Date().timeIntervalSince(start)
        return (result, duration)
    }
}

// MARK: - Mock Clock

/// A mock clock for testing that allows manual time control.
///
/// Thread Safety: This type is thread-safe through the use of NSLock which protects
/// all access to the mutable currentTime and autoAdvance properties. All operations
/// acquire the lock before accessing or modifying state.
/// Invariant: The currentTime can only advance forward (though this is not enforced).
/// The lock ensures atomic read-modify-write operations for time manipulation.
public final class MockClock: MetricClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime: Date
    private var autoAdvance: TimeInterval = 0

    /// Initialize with a specific time.
    public init(startTime: Date = Date(timeIntervalSince1970: 0)) {
        self.currentTime = startTime
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let time = currentTime
        if autoAdvance > 0 {
            currentTime = currentTime.addingTimeInterval(autoAdvance)
        }
        return time
    }

    public func timeIntervalSinceReferenceDate() -> TimeInterval {
        now().timeIntervalSinceReferenceDate
    }

    public func timeIntervalSince1970() -> TimeInterval {
        now().timeIntervalSince1970
    }

    /// Advance the clock by a specific interval.
    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        currentTime = currentTime.addingTimeInterval(interval)
    }

    /// Set the clock to a specific time.
    public func set(to date: Date) {
        lock.lock()
        defer { lock.unlock() }
        currentTime = date
    }

    /// Set auto-advance interval for each time access.
    public func setAutoAdvance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        autoAdvance = interval
    }

    public func measure<T: Sendable>(_ operation: @Sendable () throws -> T) rethrows -> (result: T, duration: TimeInterval) {
        let start = now()
        let result = try operation()
        let end = now()
        return (result, end.timeIntervalSince(start))
    }

    public func measure<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> (result: T, duration: TimeInterval) {
        let start = now()
        let result = try await operation()
        let end = now()
        return (result, end.timeIntervalSince(start))
    }
}

// MARK: - Monotonic Clock

/// A clock that uses monotonic time for accurate duration measurements.
///
/// This clock is immune to system time changes and is ideal for measuring intervals.
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public struct MonotonicClock: MetricClock {
    private let continuousClock = ContinuousClock()
    private let startTime = Date()
    private let startInstant = ContinuousClock.now

    public init() {}

    public func now() -> Date {
        let elapsed = continuousClock.now.duration(to: startInstant)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return startTime.addingTimeInterval(seconds)
    }

    public func timeIntervalSinceReferenceDate() -> TimeInterval {
        now().timeIntervalSinceReferenceDate
    }

    public func timeIntervalSince1970() -> TimeInterval {
        now().timeIntervalSince1970
    }

    public func measure<T: Sendable>(_ operation: @Sendable () throws -> T) rethrows -> (result: T, duration: TimeInterval) {
        let start = continuousClock.now
        let result = try operation()
        let elapsed = continuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (result, seconds)
    }

    public func measure<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> (result: T, duration: TimeInterval) {
        let start = continuousClock.now
        let result = try await operation()
        let elapsed = continuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (result, seconds)
    }
}

// MARK: - Clock Provider

/// A global provider for the metric clock.
public actor ClockProvider {
    private var clock: any MetricClock = SystemClock()

    /// The shared clock provider instance.
    public static let shared = ClockProvider()

    private init() {}

    /// Get the current clock.
    public var current: any MetricClock {
        clock
    }

    /// Set a custom clock (useful for testing).
    public func setClock(_ newClock: any MetricClock) {
        clock = newClock
    }

    /// Reset to the system clock.
    public func reset() {
        clock = SystemClock()
    }
}

// MARK: - Clock Extensions

public extension Metric {
    /// Create a metric with a custom clock.
    init(
        name: MetricName,
        value: MetricValue,
        clock: any MetricClock,
        tags: MetricTags = [:]
    ) {
        self.init(
            name: name,
            value: value,
            timestamp: clock.now(),
            tags: tags
        )
    }
}

public extension Metric where Kind == Timer {
    /// Measure an operation with a custom clock.
    static func measure<T: Sendable>(
        _ name: MetricName,
        unit: MetricUnit = .milliseconds,
        tags: MetricTags = [:],
        clock: any MetricClock,
        operation: @Sendable () throws -> T
    ) rethrows -> (metric: Metric<Timer>, result: T) {
        let (result, duration) = try clock.measure(operation)

        let durationValue: Double
        switch unit {
        case .nanoseconds:
            durationValue = duration * 1_000_000_000
        case .microseconds:
            durationValue = duration * 1_000_000
        case .milliseconds:
            durationValue = duration * 1_000
        case .seconds:
            durationValue = duration
        case .minutes:
            durationValue = duration / 60
        case .hours:
            durationValue = duration / 3600
        default:
            durationValue = duration * 1_000 // Default to milliseconds
        }

        let metric = timer(name, duration: durationValue, unit: unit, tags: tags)
        return (metric, result)
    }

    /// Measure an async operation with a custom clock.
    static func measure<T: Sendable>(
        _ name: MetricName,
        unit: MetricUnit = .milliseconds,
        tags: MetricTags = [:],
        clock: any MetricClock,
        operation: @Sendable () async throws -> T
    ) async rethrows -> (metric: Metric<Timer>, result: T) {
        let (result, duration) = try await clock.measure(operation)

        let durationValue: Double
        switch unit {
        case .nanoseconds:
            durationValue = duration * 1_000_000_000
        case .microseconds:
            durationValue = duration * 1_000_000
        case .milliseconds:
            durationValue = duration * 1_000
        case .seconds:
            durationValue = duration
        case .minutes:
            durationValue = duration / 60
        case .hours:
            durationValue = duration / 3600
        default:
            durationValue = duration * 1_000 // Default to milliseconds
        }

        let metric = timer(name, duration: durationValue, unit: unit, tags: tags)
        return (metric, result)
    }
}

// MARK: - Test Helpers

public extension MockClock {
    /// Create a sequence of timestamps for testing.
    ///
    /// - Parameters:
    ///   - start: The starting date
    ///   - interval: The interval between timestamps
    ///   - count: The number of timestamps to generate
    /// - Returns: An array of dates
    static func sequence(
        from start: Date,
        interval: TimeInterval,
        count: Int
    ) -> [Date] {
        (0..<count).map { start.addingTimeInterval(TimeInterval($0) * interval) }
    }

    /// Simulate a series of metric recordings with specific timing.
    ///
    /// - Parameters:
    ///   - intervals: The time intervals between recordings
    ///   - operation: The operation to perform at each interval
    func simulate(
        intervals: [TimeInterval],
        operation: () async -> Void
    ) async {
        for interval in intervals {
            advance(by: interval)
            await operation()
        }
    }
}
