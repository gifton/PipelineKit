import Foundation

/// Token bucket implementation for rate limiting.
internal actor TokenBucket {
    private let capacity: Double
    private var tokens: Double
    private var lastRefill: Date
    private var lastAccess: Date
    
    init(capacity: Double) {
        self.capacity = capacity
        self.tokens = capacity
        self.lastRefill = Date()
        self.lastAccess = Date()
    }
    
    func refill(rate: Double) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let tokensToAdd = elapsed * rate
        
        tokens = min(capacity, tokens + tokensToAdd)
        lastRefill = now
        lastAccess = now
    }
    
    func consume(tokens: Double) -> Bool {
        guard self.tokens >= tokens else { return false }
        self.tokens -= tokens
        lastAccess = Date()
        return true
    }
    
    func timeToNextToken() -> TimeInterval {
        guard tokens < capacity else { return 0 }
        return 1.0 // Simplified: 1 second per token
    }
    
    func getTokens() -> Double {
        return tokens
    }
    
    func getLastAccess() -> Date {
        return lastAccess
    }
}