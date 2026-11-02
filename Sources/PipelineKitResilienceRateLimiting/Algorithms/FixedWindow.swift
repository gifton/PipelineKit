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
        self.now = now
        self.windowSize = windowSize
        self.currentWindow = Self.alignToWindow(now(), windowSize: windowSize)
    }

    func recordRequest() -> (count: Int, windowStart: Date) {
        let now = self.now()
        let alignedWindow = Self.alignToWindow(now, windowSize: windowSize)

        // Check if we've moved to a new window
        if alignedWindow != currentWindow {
            // Reset counter for new window
            currentWindow = alignedWindow
            requestCount = 0
        }

        requestCount += 1
        return (requestCount, currentWindow)
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

    /// Aligns a date to the start of its window
    private static func alignToWindow(_ date: Date, windowSize: TimeInterval) -> Date {
        let timestamp = date.timeIntervalSince1970
        let alignedTimestamp = floor(timestamp / windowSize) * windowSize
        return Date(timeIntervalSince1970: alignedTimestamp)
    }
}
