import Foundation

/// Fixed window counter implementation for rate limiting.
/// 
/// This is a simpler but less accurate algorithm compared to sliding window.
/// It can allow traffic bursts at window boundaries.
internal actor FixedWindow {
    private let now: @Sendable () -> Date
    private let windowSize: TimeInterval
    private var currentWindow: Date
    private var requestCount: Int = 0

    init(windowSize: TimeInterval = 60.0, now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(windowSize.isFinite && windowSize > 0, "Rate limit window must be finite and positive")
        self.now = now
        self.windowSize = windowSize
        self.currentWindow = Self.alignToWindow(now(), windowSize: windowSize)
    }

    func recordRequest() -> (count: Int?, windowStart: Date) {
        let now = self.now()
        let alignedWindow = Self.alignToWindow(now, windowSize: windowSize)

        // Check if we've moved to a new window
        if alignedWindow != currentWindow {
            // Reset counter for new window
            currentWindow = alignedWindow
            requestCount = 0
        }

        guard let nextCount = RateLimitNumeric.increment(requestCount) else { return (nil, currentWindow) }
        requestCount = nextCount
        return (nextCount, currentWindow)
    }

    func getCurrentCount() -> Int {
        let now = self.now()
        let alignedWindow = Self.alignToWindow(now, windowSize: windowSize)

        // Check if we're still in the same window
        if alignedWindow != currentWindow {
            return 0
        }

        return requestCount
    }

    func timeUntilReset() -> TimeInterval {
        let nextWindow = currentWindow.addingTimeInterval(windowSize)
        return nextWindow.timeIntervalSince(now())
    }

    func reset() {
        requestCount = 0
        currentWindow = Self.alignToWindow(now(), windowSize: windowSize)
    }

    func isNeutralForEviction() -> Bool {
        Self.alignToWindow(now(), windowSize: windowSize) != currentWindow
    }

    /// Aligns a date to the start of its window
    private static func alignToWindow(_ date: Date, windowSize: TimeInterval) -> Date {
        let timestamp = date.timeIntervalSince1970
        let remainder = timestamp.truncatingRemainder(dividingBy: windowSize)
        let alignedTimestamp = timestamp - remainder - (remainder < 0 ? windowSize : 0)
        return Date(timeIntervalSince1970: alignedTimestamp)
    }
}
