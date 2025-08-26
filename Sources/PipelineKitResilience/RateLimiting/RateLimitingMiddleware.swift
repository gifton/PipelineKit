import Foundation
import PipelineKit

/// Middleware that enforces rate limiting on command execution.
///
/// Example:
/// ```swift
/// let limiter = RateLimiter(
///     strategy: .tokenBucket(capacity: 100, refillRate: 10),
///     scope: .perUser
/// )
/// let middleware = RateLimitingMiddleware(limiter: limiter)
/// ```
public struct RateLimitingMiddleware: Middleware {
    public let priority: ExecutionPriority = .authentication
    private let limiter: RateLimiter
    private let identifierExtractor: @Sendable (any Command, CommandContext) async -> String
    private let costCalculator: @Sendable (any Command) -> Double
    /// Creates rate limiting middleware.
    ///
    /// - Parameters:
    ///   - limiter: The rate limiter to use
    ///   - identifierExtractor: Function to extract identifier from command/metadata
    ///   - costCalculator: Function to calculate request cost
    public init(
        limiter: RateLimiter,
        identifierExtractor: @escaping @Sendable (any Command, CommandContext) async -> String = { _, context in
            let metadata = context.commandMetadata
            return metadata.userId ?? "anonymous"
        },
        costCalculator: @escaping @Sendable (any Command) -> Double = { _ in 1.0 }
    ) {
        self.limiter = limiter
        self.identifierExtractor = identifierExtractor
        self.costCalculator = costCalculator
    }
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let identifier = await identifierExtractor(command, context)
        let cost = costCalculator(command)
        guard try await limiter.allowRequest(identifier: identifier, cost: cost) else {
            let status = await limiter.getStatus(identifier: identifier)
            throw PipelineError.rateLimitExceeded(
                limit: status.limit,
                resetTime: status.resetAt,
                retryAfter: status.resetAt.timeIntervalSinceNow
            )
        }
        return try await next(command, context)
    }
}
