import Foundation

/// Leaky bucket implementation for rate limiting.
/// 
/// Similar to token bucket but with a constant output rate.
/// Requests are queued and processed at a fixed rate.
internal actor LeakyBucket {
    private let capacity: Int
    private let leakRate: TimeInterval // seconds between leaks
    private var currentLevel: Int = 0
    private var lastLeakTime: Date

    init(capacity: Int, leakRate: TimeInterval) {
        self.capacity = capacity
        self.leakRate = leakRate
        self.lastLeakTime = Date()
    }

    func tryAdd() -> Bool {
        // First, leak accumulated requests
        leak()

        // Check if bucket has capacity
        guard currentLevel < capacity else {
            return false
        }

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
        return max(0, nextLeakTime.timeIntervalSinceNow)
    }

    func reset() {
        currentLevel = 0
        lastLeakTime = Date()
    }

    private func leak() {
        let now = Date()
        let timeSinceLastLeak = now.timeIntervalSince(lastLeakTime)

        // Calculate how many items have leaked
        let leakedItems = Int(timeSinceLastLeak / leakRate)

        if leakedItems > 0 {
            currentLevel = max(0, currentLevel - leakedItems)
            // Update last leak time to account for processed leaks
            lastLeakTime = lastLeakTime.addingTimeInterval(Double(leakedItems) * leakRate)
        }
    }
}
