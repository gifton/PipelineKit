import Foundation
import PipelineKit

/// Enhanced rate limiting middleware with support for priority-based strategies.
///
/// Example:
/// ```swift
/// // Priority-based rate limiting
/// let limiter = RateLimiter(
///     strategy: .priorityBased(limits: [
///         .critical: RateLimitConfig(maxRequests: 1000, windowSize: 60),
///         .high: RateLimitConfig(maxRequests: 500, windowSize: 60),
///         .medium: RateLimitConfig(maxRequests: 200, windowSize: 60),
///         .low: RateLimitConfig(maxRequests: 50, windowSize: 60)
///     ])
/// )
/// let middleware = EnhancedRateLimitingMiddleware(
///     limiter: limiter,
///     priorityExtractor: { command, context in
///         // Extract priority from command or context
///         if let priorityCommand = command as? PriorityCommand {
///             return priorityCommand.priority
///         }
///         return .medium
///     }
/// )
/// ```
public struct EnhancedRateLimitingMiddleware: Middleware {
    public let priority: ExecutionPriority = .authentication
    private let limiter: RateLimiter
    private let identifierExtractor: @Sendable (any Command, CommandContext) async -> String
    private let costCalculator: @Sendable (any Command) -> Double
    private let priorityExtractor: @Sendable (any Command, CommandContext) async -> Priority

    /// Creates enhanced rate limiting middleware.
    ///
    /// - Parameters:
    ///   - limiter: The rate limiter to use
    ///   - identifierExtractor: Function to extract identifier from command/metadata
    ///   - costCalculator: Function to calculate request cost
    ///   - priorityExtractor: Function to extract priority level
    public init(
        limiter: RateLimiter,
        identifierExtractor: @escaping @Sendable (any Command, CommandContext) async -> String = { _, context in
            let metadata = context.commandMetadata
            return metadata.userID ?? "anonymous"
        },
        costCalculator: @escaping @Sendable (any Command) -> Double = { _ in 1.0 },
        priorityExtractor: @escaping @Sendable (any Command, CommandContext) async -> Priority = { _, _ in .medium }
    ) {
        self.limiter = limiter
        self.identifierExtractor = identifierExtractor
        self.costCalculator = costCalculator
        self.priorityExtractor = priorityExtractor
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let identifier = await identifierExtractor(command, context)
        let cost = costCalculator(command)
        let priority = await priorityExtractor(command, context)

        // Store priority in context for the rate limiter to use
        await context.setMetadata("rateLimitPriority", value: priority.rawValue)

        guard try await limiter.allowRequest(identifier: identifier, cost: cost) else {
            let status = await limiter.getStatus(identifier: identifier)

            // Store rate limit info in context
            await context.setMetadata("rateLimitExceeded", value: true)
            await context.setMetadata("rateLimitIdentifier", value: identifier)
            await context.setMetadata("rateLimitPriority", value: priority.rawValue)
            await context.setMetadata("rateLimitStatus", value: [
                "limit": status.limit,
                "remaining": status.remaining,
                "resetAt": status.resetAt,
                "retryAfter": status.resetAt.timeIntervalSinceNow
            ] as [String: any Sendable])

            throw PipelineError.rateLimitExceeded(
                limit: status.limit,
                resetTime: status.resetAt,
                retryAfter: status.resetAt.timeIntervalSinceNow
            )
        }

        // Track successful rate limit checks
        let currentMetrics = await context.getMetadata()
        let currentChecks = (currentMetrics["rateLimitChecks"] as? Int) ?? 0
        await context.setMetadata("rateLimitChecks", value: currentChecks + 1)

        return try await next(command, context)
    }
}

/// Protocol for commands that specify their own priority
public protocol PriorityCommand: Command {
    var priority: Priority { get }
}

/// Protocol for commands that specify their own rate limit cost
public protocol CostAwareCommand: Command {
    var cost: Double { get }
}

/// Convenience factory methods for common rate limiting configurations
public extension RateLimiter {
    /// Creates a rate limiter with token bucket strategy
    static func tokenBucket(
        capacity: Double,
        refillRate: Double,
        scope: RateLimitScope = .perUser
    ) -> RateLimiter {
        RateLimiter(
            strategy: .tokenBucket(capacity: capacity, refillRate: refillRate),
            scope: scope
        )
    }

    /// Creates a rate limiter with sliding window strategy
    static func slidingWindow(
        windowSize: TimeInterval,
        maxRequests: Int,
        scope: RateLimitScope = .perUser
    ) -> RateLimiter {
        RateLimiter(
            strategy: .slidingWindow(windowSize: windowSize, maxRequests: maxRequests),
            scope: scope
        )
    }

    /// Creates a rate limiter with fixed window strategy
    static func fixedWindow(
        windowSize: TimeInterval,
        maxRequests: Int,
        scope: RateLimitScope = .perUser
    ) -> RateLimiter {
        RateLimiter(
            strategy: .fixedWindow(windowSize: windowSize, maxRequests: maxRequests),
            scope: scope
        )
    }

    /// Creates a rate limiter with leaky bucket strategy
    static func leakyBucket(
        capacity: Int,
        leakRate: TimeInterval,
        scope: RateLimitScope = .perUser
    ) -> RateLimiter {
        RateLimiter(
            strategy: .leakyBucket(capacity: capacity, leakRate: leakRate),
            scope: scope
        )
    }

    /// Creates a rate limiter with priority-based strategy
    static func priorityBased(
        limits: [Priority: RateLimitConfig],
        scope: RateLimitScope = .perUser
    ) -> RateLimiter {
        RateLimiter(
            strategy: .priorityBased(limits: limits),
            scope: scope
        )
    }
}
