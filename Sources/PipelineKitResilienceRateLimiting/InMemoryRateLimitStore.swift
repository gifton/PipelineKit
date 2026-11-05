import Foundation
import PipelineKitCore

/// In-memory implementation of distributed rate limit store.
/// 
/// This is suitable for single-instance deployments or testing.
/// For production multi-instance deployments, use Redis or another
/// distributed store implementation.
public actor InMemoryRateLimitStore: DistributedRateLimitStore {
    private var counters: [String: WindowCounter] = [:]
    private let cleanupInterval: TimeInterval = 300 // 5 minutes
    private var lastCleanup = Date()

    private struct WindowCounter {
        let windowStart: Date
        let windowSize: TimeInterval
        var count: Int

        var isExpired: Bool {
            Date().timeIntervalSince(windowStart) / 2 > windowSize
        }
    }

    public init() {}

    public func incrementAndGet(
        key: String,
        windowSize: TimeInterval
    ) async throws -> Int {
        guard windowSize.isFinite && windowSize > 0 else {
            throw PipelineError.validation(field: "windowSize", reason: .custom("Rate limit window must be finite and positive"))
        }
        await cleanupIfNeeded()

        let now = Date()
        let windowStart = alignToWindow(now, windowSize: windowSize)

        if let existing = counters[key],
           existing.windowStart == windowStart {
            // Same window, increment
            guard let count = RateLimitNumeric.increment(existing.count) else {
                throw PipelineError.validation(field: "count", reason: .custom("Rate limit count exceeds Int.max"))
            }
            counters[key]?.count = count
            return count
        } else {
            // New window
            counters[key] = WindowCounter(
                windowStart: windowStart,
                windowSize: windowSize,
                count: 1
            )
            return 1
        }
    }

    public func getCount(
        key: String,
        windowSize: TimeInterval
    ) async throws -> Int {
        guard windowSize.isFinite && windowSize > 0 else {
            throw PipelineError.validation(field: "windowSize", reason: .custom("Rate limit window must be finite and positive"))
        }
        let now = Date()
        let windowStart = alignToWindow(now, windowSize: windowSize)

        if let existing = counters[key],
           existing.windowStart == windowStart {
            return existing.count
        }

        return 0
    }

    public func reset(key: String) async throws {
        counters.removeValue(forKey: key)
    }

    private func alignToWindow(_ date: Date, windowSize: TimeInterval) -> Date {
        let timestamp = date.timeIntervalSince1970
        let remainder = timestamp.truncatingRemainder(dividingBy: windowSize)
        let alignedTimestamp = timestamp - remainder - (remainder < 0 ? windowSize : 0)
        return Date(timeIntervalSince1970: alignedTimestamp)
    }

    private func cleanupIfNeeded() async {
        let now = Date()
        guard now.timeIntervalSince(lastCleanup) >= cleanupInterval else { return }

        // Remove expired counters
        counters = counters.filter { !$0.value.isExpired }
        lastCleanup = now
    }
}

/// Redis-based implementation placeholder.
/// 
/// This would use Redis INCR with TTL for atomic distributed counting.
/// Example implementation:
/// ```swift
/// public actor RedisRateLimitStore: DistributedRateLimitStore {
///     private let redis: RedisClient
///     
///     public func incrementAndGet(
///         key: String,
///         windowSize: TimeInterval
///     ) async throws -> Int {
///         let windowKey = "\(key):\(Int(Date().timeIntervalSince1970 / windowSize))"
///         let count = try await redis.incr(windowKey)
///         if count == 1 {
///             try await redis.expire(windowKey, seconds: Int(windowSize))
///         }
///         return count
///     }
/// }
/// ```
public struct RedisRateLimitStorePlaceholder {
    // This is a placeholder for Redis-based implementation
    // Actual implementation would depend on the Redis client library used
}
