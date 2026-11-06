import Foundation

/// Leaky bucket implementation for rate limiting.
/// 
/// Similar to token bucket but with a constant output rate.
/// Requests are queued and processed at a fixed rate.
internal actor LeakyBucket {
    private let now: @Sendable () -> Date
    private let capacity: Int
    private let leakRate: TimeInterval // seconds between leaks
    private var currentLevel: Int = 0
    private var lastLeakTime: Date

    init(capacity: Int, leakRate: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(capacity >= 0, "Leaky bucket capacity must be nonnegative")
        precondition(leakRate.isFinite && leakRate > 0, "Leak interval must be finite and positive")
        self.now = now
        self.capacity = capacity
        self.leakRate = leakRate
        self.lastLeakTime = now()
    }

    func tryAdd() -> Bool {
        // First, leak accumulated requests
        leak()

        // Check if bucket has capacity
        guard currentLevel < capacity else {
            return false
        }

        // Idle time does not prepay the next request's leak interval.
        // testLeakyIdleCycleStartsAtNewAdmissionWithOrWithoutReclamation.
        if currentLevel == 0 { lastLeakTime = now() }
        currentLevel += 1
        return true
    }

    func getCurrentLevel() -> Int {
        leak()
        return currentLevel
    }

    func timeUntilNextLeak() -> TimeInterval {
        guard currentLevel > 0 else { return 0 }

        let nextLeakTime = lastLeakTime.addingTimeInterval(leakRate)
        return max(0, nextLeakTime.timeIntervalSince(now()))
    }

    func reset() {
        currentLevel = 0
        lastLeakTime = now()
    }

    func isNeutralForEviction() -> Bool {
        leak()
        return currentLevel == 0
    }

    private func leak() {
        let now = self.now()
        let timeSinceLastLeak = now.timeIntervalSince(lastLeakTime)

        // Calculate how many items have leaked
        guard timeSinceLastLeak > 0 else { return }
        let elapsedLeaks = timeSinceLastLeak / leakRate
        if elapsedLeaks >= Double(currentLevel) {
            currentLevel = 0
            // Preserve the fractional leak phase without converting the unbounded quotient.
            lastLeakTime = now.addingTimeInterval(-timeSinceLastLeak.truncatingRemainder(dividingBy: leakRate))
            return
        }
        let leakedItems = Int(elapsedLeaks)

        if leakedItems > 0 {
            currentLevel = max(0, currentLevel - leakedItems)
            // Update last leak time to account for processed leaks
            lastLeakTime = lastLeakTime.addingTimeInterval(Double(leakedItems) * leakRate)
        }
    }
}
