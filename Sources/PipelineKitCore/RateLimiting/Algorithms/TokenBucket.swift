import Foundation

/// Token bucket implementation for rate limiting.
internal actor TokenBucket {
    private let capacity: Double
    private var tokens: Double
    private var lastRefill: Date
    private var lastAccess: Date
    private var refillRate: Double
    
    init(capacity: Double, refillRate: Double = 1.0) {
        self.capacity = capacity
        self.tokens = capacity
        self.lastRefill = Date()
        self.lastAccess = Date()
        self.refillRate = refillRate
    }
    
    func refill(rate: Double) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let tokensToAdd = elapsed * rate
        
        tokens = min(capacity, tokens + tokensToAdd)
        lastRefill = now
        lastAccess = now
        // Update the refill rate for accurate time calculations
        refillRate = rate
    }
    
    func consume(tokens: Double) -> Bool {
        guard self.tokens >= tokens else { return false }
        self.tokens -= tokens
        lastAccess = Date()
        return true
    }
    
    func timeToNextToken() -> TimeInterval {
        guard tokens < capacity else { return 0 }
        // Calculate time based on actual refill rate (tokens per second)
        // If refill rate is 10 tokens/second, time per token is 1/10 = 0.1 seconds
        guard refillRate > 0 else { return 1.0 } // Fallback to 1 second if rate is invalid
        return 1.0 / refillRate
    }
    
    func getTokens() -> Double {
        return tokens
    }
    
    func getLastAccess() -> Date {
        return lastAccess
    }
}