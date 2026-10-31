import Foundation
#if !canImport(Darwin)
@inline(__always)
func autoreleasepool<T>(invoking body: () -> T) -> T { body() }
#endif

/// Sliding window implementation for rate limiting.
internal actor SlidingWindow {
    private let now: @Sendable () -> Date
    private var requests: [Date] = []
    private var windowSize: TimeInterval = 60.0
    
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func setWindowSize(_ size: TimeInterval) {
        windowSize = size
    }
    
    func recordRequest() {
        autoreleasepool {
            let now = self.now()
            requests.append(now)
            
            // Clean up old requests outside the window
            let cutoff = now.addingTimeInterval(-windowSize * 2)
            requests.removeAll { $0 < cutoff }
        }
    }
    
    func requestCount(since date: Date) -> Int {
        autoreleasepool {
            requests.filter { $0 >= date }.count
        }
    }
    
    func hasRecentRequests(within interval: TimeInterval) -> Bool {
        autoreleasepool {
            let cutoff = now().addingTimeInterval(-interval)
            return requests.contains { $0 >= cutoff }
        }
    }
}
