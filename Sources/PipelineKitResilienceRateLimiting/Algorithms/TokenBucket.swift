import Foundation

/// Token bucket implementation for rate limiting.
internal actor TokenBucket {
    private let now: @Sendable () -> Date
    private let capacity: Double
    private var tokens: Double
    private var lastRefill: Date
    private var lastAccess: Date
    private var refillRate: Double
    
    init(
        capacity: Double,
        refillRate: Double = 1.0,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(capacity.isFinite && capacity >= 0, "Token capacity must be finite and nonnegative")
        precondition(refillRate.isFinite && refillRate >= 0, "Refill rate must be finite and nonnegative")
        self.now = now
        self.capacity = capacity
        self.tokens = capacity
        self.lastRefill = now()
        self.lastAccess = now()
        self.refillRate = refillRate
    }
    
    func refill(rate: Double) {
        precondition(rate.isFinite && rate >= 0, "Refill rate must be finite and nonnegative")
        let now = self.now()
        tokens = refilledTokens(rate: rate, at: now)
        lastRefill = now
        lastAccess = now
        // Update the refill rate for accurate time calculations
        refillRate = rate
    }
    
    func consume(tokens: Double) -> Bool {
        guard tokens.isFinite && tokens >= 0, self.tokens >= tokens else { return false }
        self.tokens -= tokens
        lastAccess = now()
        return true
    }
    
    func timeToNextToken() -> TimeInterval {
        guard tokens < capacity else { return 0 }
        // Calculate time based on actual refill rate (tokens per second)
        // If refill rate is 10 tokens/second, time per token is 1/10 = 0.1 seconds
        guard refillRate > 0 else { return 1.0 } // Fallback to 1 second if rate is invalid
        return min(Double.greatestFiniteMagnitude, 1.0 / refillRate)
    }
    
    func getTokens() -> Double {
        return tokens
    }
    
    func getLastAccess() -> Date {
        return lastAccess
    }

    func isNeutralForEviction(refillRate: Double) -> Bool {
        refilledTokens(rate: refillRate, at: now()) >= capacity
    }

    private func refilledTokens(rate: Double, at date: Date) -> Double {
        guard rate > 0, tokens < capacity else { return tokens }
        let elapsed = max(0, date.timeIntervalSince(lastRefill))
        let added: Double
        if elapsed.isFinite {
            added = elapsed * rate
        } else {
            // Finite instants can have an unrepresentable difference. Scaling
            // opposite-sign endpoints first preserves subnormal refill rates.
            // testExtremeClockSpanDoesNotRefillZeroRateOrPoisonFractionalBudget.
            added = date.timeIntervalSinceReferenceDate * rate - lastRefill.timeIntervalSinceReferenceDate * rate
        }
        return min(capacity, tokens + added)
    }
}
