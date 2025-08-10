import Foundation

/// High-precision timing utilities optimized for minimal overhead.
public struct Timing: Sendable {
    /// Total time for all iterations.
    public let total: TimeInterval

    /// Average time per iteration.
    public let average: TimeInterval

    /// Minimum time recorded.
    public let min: TimeInterval

    /// Maximum time recorded.
    public let max: TimeInterval

    /// Format the timing as a human-readable string.
    public func formatted() -> String {
        let formatter = DurationFormatter()
        return """
        Total: \(formatter.format(total))
        Average: \(formatter.format(average))
        Min: \(formatter.format(min))
        Max: \(formatter.format(max))
        """
    }
}

/// Time a synchronous operation with minimal overhead.
///
/// This function is marked @inlinable and @inline(__always) to ensure
/// zero overhead when timing operations.
@inlinable
@inline(__always)
public func time<T>(_ operation: () throws -> T) rethrows -> (result: T, duration: TimeInterval) {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try operation()
    let duration = CFAbsoluteTimeGetCurrent() - start
    return (result, duration)
}

/// Time an asynchronous operation with minimal overhead.
@inlinable
@inline(__always)
public func time<T>(_ operation: () async throws -> T) async rethrows -> (result: T, duration: TimeInterval) {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try await operation()
    let duration = CFAbsoluteTimeGetCurrent() - start
    return (result, duration)
}

/// Measure elapsed time for a block of code.
@inlinable
@inline(__always)
public func measure(_ operation: () throws -> Void) rethrows -> TimeInterval {
    let start = CFAbsoluteTimeGetCurrent()
    try operation()
    return CFAbsoluteTimeGetCurrent() - start
}

/// Measure elapsed time for an async block of code.
@inlinable
@inline(__always)
public func measure(_ operation: () async throws -> Void) async rethrows -> TimeInterval {
    let start = CFAbsoluteTimeGetCurrent()
    try await operation()
    return CFAbsoluteTimeGetCurrent() - start
}

/// A high-precision timer for manual timing control.
public struct Timer: Sendable {
    @usableFromInline
    internal let startTime: CFAbsoluteTime // swiftlint:disable:this attributes

    /// Create a new timer starting now.
    @inlinable
    public init() {
        self.startTime = CFAbsoluteTimeGetCurrent()
    }

    /// Get the elapsed time since the timer was created.
    @inlinable
    public var elapsed: TimeInterval { // swiftlint:disable:this attributes
        CFAbsoluteTimeGetCurrent() - startTime
    }

    /// Create a new lap timer from this point.
    @inlinable
    public func lap() -> Timer {
        Timer()
    }
}

/// Format durations in human-readable format.
struct DurationFormatter {
    /// Format a duration with appropriate units.
    func format(_ duration: TimeInterval) -> String {
        switch duration {
        case ..<0.000_001:
            return String(format: "%.1fns", duration * 1_000_000_000)
        case 0.000_001..<0.001:
            return String(format: "%.1fμs", duration * 1_000_000)
        case 0.001..<1.0:
            return String(format: "%.1fms", duration * 1_000)
        default:
            return String(format: "%.3fs", duration)
        }
    }

    /// Format throughput (operations per second).
    func formatThroughput(_ operationsPerSecond: Double) -> String {
        switch operationsPerSecond {
        case ..<1_000:
            return String(format: "%.0f ops/sec", operationsPerSecond)
        case 1_000..<1_000_000:
            return String(format: "%.1fK ops/sec", operationsPerSecond / 1_000)
        default:
            return String(format: "%.1fM ops/sec", operationsPerSecond / 1_000_000)
        }
    }

    /// Format latency with appropriate precision.
    func formatLatency(_ latency: TimeInterval) -> String {
        switch latency {
        case ..<0.000_001:
            return String(format: "%.0fns", latency * 1_000_000_000)
        case 0.000_001..<0.001:
            return String(format: "%.1fμs", latency * 1_000_000)
        case 0.001..<1.0:
            return String(format: "%.1fms", latency * 1_000)
        default:
            return String(format: "%.2fs", latency)
        }
    }
}

// MARK: - Timing Extensions

public extension Array where Element == TimeInterval {
    /// Calculate throughput from timing data.
    var throughput: Double {
        let totalTime = reduce(0, +)
        return totalTime > 0 ? Double(count) / totalTime : 0
    }

    /// Calculate average latency.
    var averageLatency: TimeInterval {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
}
