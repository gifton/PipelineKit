import Foundation

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
    private let limiter: RateLimiter
    private let identifierExtractor: @Sendable (any Command, CommandMetadata) -> String
    private let costCalculator: @Sendable (any Command) -> Double
    
    /// Creates rate limiting middleware.
    ///
    /// - Parameters:
    ///   - limiter: The rate limiter to use
    ///   - identifierExtractor: Function to extract identifier from command/metadata
    ///   - costCalculator: Function to calculate request cost
    public init(
        limiter: RateLimiter,
        identifierExtractor: @escaping @Sendable (any Command, CommandMetadata) -> String = { _, metadata in
            metadata.userId ?? "anonymous"
        },
        costCalculator: @escaping @Sendable (any Command) -> Double = { _ in 1.0 }
    ) {
        self.limiter = limiter
        self.identifierExtractor = identifierExtractor
        self.costCalculator = costCalculator
    }
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        let identifier = identifierExtractor(command, metadata)
        let cost = costCalculator(command)
        
        guard try await limiter.allowRequest(identifier: identifier, cost: cost) else {
            let status = await limiter.getStatus(identifier: identifier)
            throw RateLimitError.limitExceeded(
                remaining: status.remaining,
                resetAt: status.resetAt
            )
        }
        
        return try await next(command, metadata)
    }
}

// Extension to make RateLimitingMiddleware an PrioritizedMiddleware
extension RateLimitingMiddleware: PrioritizedMiddleware {
    /// Recommended middleware order for this component
    public static var recommendedOrder: ExecutionPriority { .rateLimiting }
}