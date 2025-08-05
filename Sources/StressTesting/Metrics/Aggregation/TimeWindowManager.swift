import PipelineKitMiddleware
import Foundation
import PipelineKit

/// Manages time-based aggregation windows for metrics.
///
/// TimeWindowManager handles:
/// - Multiple time window sizes (1min, 5min, 15min, etc.)
/// - Automatic window rotation
/// - Efficient memory usage with window limits
/// - Thread-safe access via actor isolation
public actor TimeWindowManager {
    /// Configuration for time window management.
    public struct Configuration: Sendable {
        /// Supported time window durations.
        public let windowDurations: Set<TimeInterval>
        
        /// Maximum number of windows to keep per duration.
        public let maxWindowsPerDuration: Int
        
        /// How often to check for window rotation.
        public let rotationCheckInterval: TimeInterval
        
        public init(
            windowDurations: Set<TimeInterval> = [60, 300, 900], // 1min, 5min, 15min
            maxWindowsPerDuration: Int = 60, // ~1 hour of 1-minute windows
            rotationCheckInterval: TimeInterval = 10
        ) {
            self.windowDurations = windowDurations
            self.maxWindowsPerDuration = maxWindowsPerDuration
            self.rotationCheckInterval = rotationCheckInterval
        }
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    private var metricWindows: [String: MetricWindows] = [:]
    private var rotationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    // MARK: - Public API
    
    /// Starts the automatic window rotation.
    public func start() {
        guard rotationTask == nil else { return }
        
        rotationTask = Task {
            await runRotationLoop()
        }
    }
    
    /// Stops the automatic window rotation.
    public func stop() {
        rotationTask?.cancel()
        rotationTask = nil
    }
    
    /// Adds a metric sample to appropriate windows.
    public func add(_ sample: MetricDataPoint) {
        let windows = ensureWindows(for: sample.name, type: sample.type)
        windows.add(sample)
    }
    
    /// Queries aggregated metrics for a time range.
    public func query(_ query: MetricQuery) -> [AggregatedMetrics] {
        var results: [AggregatedMetrics] = []
        
        for (metricName, windows) in metricWindows {
            guard query.matches(name: metricName) else { continue }
            
            for duration in query.windows {
                guard configuration.windowDurations.contains(duration) else { continue }
                
                let aggregated = windows.query(
                    duration: duration,
                    timeRange: query.timeRange
                )
                results.append(contentsOf: aggregated)
            }
        }
        
        return results.sorted { $0.timestamp < $1.timestamp }
    }
    
    /// Gets current statistics about managed windows.
    public func statistics() -> WindowStatistics {
        var totalWindows = 0
        var totalDataPoints = 0
        let metricCount = metricWindows.count
        
        for (_, windows) in metricWindows {
            let stats = windows.statistics()
            totalWindows += stats.windowCount
            totalDataPoints += stats.dataPointCount
        }
        
        return WindowStatistics(
            metricCount: metricCount,
            totalWindows: totalWindows,
            totalDataPoints: totalDataPoints,
            windowDurations: configuration.windowDurations
        )
    }
    
    // MARK: - Private Methods
    
    private func ensureWindows(for metric: String, type: MetricType) -> MetricWindows {
        if let windows = metricWindows[metric] {
            return windows
        }
        
        let windows = MetricWindows(
            metricName: metric,
            metricType: type,
            windowDurations: configuration.windowDurations,
            maxWindowsPerDuration: configuration.maxWindowsPerDuration
        )
        metricWindows[metric] = windows
        return windows
    }
    
    private func runRotationLoop() async {
        while !Task.isCancelled {
            rotateWindows()
            
            try? await Task.sleep(nanoseconds: UInt64(configuration.rotationCheckInterval * 1_000_000_000))
        }
    }
    
    private func rotateWindows() {
        let now = Date()
        
        for (_, windows) in metricWindows {
            windows.rotate(at: now)
        }
    }
}

// MARK: - MetricWindows

/// Manages windows for a single metric.
private final class MetricWindows {
    let metricName: String
    let metricType: MetricType
    let windowDurations: Set<TimeInterval>
    let maxWindowsPerDuration: Int
    
    // Duration -> [Window]
    private var windows: [TimeInterval: [WindowAccumulator]] = [:]
    
    init(
        metricName: String,
        metricType: MetricType,
        windowDurations: Set<TimeInterval>,
        maxWindowsPerDuration: Int
    ) {
        self.metricName = metricName
        self.metricType = metricType
        self.windowDurations = windowDurations
        self.maxWindowsPerDuration = maxWindowsPerDuration
        
        // Initialize windows for each duration
        for duration in windowDurations {
            windows[duration] = []
        }
    }
    
    func add(_ sample: MetricDataPoint) {
        for duration in windowDurations {
            let window = ensureCurrentWindow(duration: duration, at: sample.timestamp)
            window.add(sample)
        }
    }
    
    func query(duration: TimeInterval, timeRange: ClosedRange<Date>) -> [AggregatedMetrics] {
        guard let durationWindows = windows[duration] else { return [] }
        
        return durationWindows.compactMap { window in
            guard timeRange.overlaps(window.timeWindow.startTime...window.timeWindow.endTime) else {
                return nil
            }
            
            return AggregatedMetrics(
                name: metricName,
                type: metricType,
                window: window.timeWindow,
                timestamp: window.timeWindow.endTime,
                statistics: window.statistics()
            )
        }
    }
    
    func rotate(at now: Date) {
        for duration in windowDurations {
            rotateWindows(duration: duration, at: now)
        }
    }
    
    func statistics() -> (windowCount: Int, dataPointCount: Int) {
        var windowCount = 0
        var dataPointCount = 0
        
        for (_, durationWindows) in windows {
            windowCount += durationWindows.count
            for window in durationWindows {
                dataPointCount += window.sampleCount
            }
        }
        
        return (windowCount, dataPointCount)
    }
    
    private func ensureCurrentWindow(duration: TimeInterval, at timestamp: Date) -> WindowAccumulator {
        var durationWindows = windows[duration] ?? []
        
        // Find or create window containing timestamp
        if let current = durationWindows.last,
           current.timeWindow.contains(timestamp) {
            return current
        }
        
        // Need new window
        let windowStart = floor(timestamp.timeIntervalSince1970 / duration) * duration
        let window = TimeWindow(
            duration: duration,
            startTime: Date(timeIntervalSince1970: windowStart)
        )
        
        let accumulator = WindowAccumulator(
            timeWindow: window,
            metricType: metricType
        )
        
        durationWindows.append(accumulator)
        
        // Trim old windows if needed
        if durationWindows.count > maxWindowsPerDuration {
            durationWindows.removeFirst()
        }
        
        windows[duration] = durationWindows
        return accumulator
    }
    
    private func rotateWindows(duration: TimeInterval, at now: Date) {
        guard var durationWindows = windows[duration],
              let lastWindow = durationWindows.last else {
            return
        }
        
        // Check if we need a new window
        if !lastWindow.timeWindow.contains(now) {
            let newWindow = lastWindow.timeWindow.next()
            let accumulator = WindowAccumulator(
                timeWindow: newWindow,
                metricType: metricType
            )
            
            durationWindows.append(accumulator)
            
            // Trim old windows
            if durationWindows.count > maxWindowsPerDuration {
                durationWindows.removeFirst()
            }
            
            windows[duration] = durationWindows
        }
    }
}

// MARK: - WindowAccumulator

/// Accumulator for a specific time window.
private final class WindowAccumulator {
    let timeWindow: TimeWindow
    let metricType: MetricType
    private var accumulator: any StatisticsAccumulator
    
    init(timeWindow: TimeWindow, metricType: MetricType) {
        self.timeWindow = timeWindow
        self.metricType = metricType
        
        // Create appropriate accumulator based on metric type
        switch metricType {
        case .gauge:
            self.accumulator = GaugeAccumulator()
        case .counter:
            self.accumulator = CounterAccumulator()
        case .histogram, .timer:
            self.accumulator = HistogramAccumulator()
        }
    }
    
    func add(_ sample: MetricDataPoint) {
        // Type-safe accumulator update
        switch (metricType, accumulator) {
        case (.gauge, var gauge as GaugeAccumulator):
            gauge.add(sample.value, at: sample.timestamp)
            accumulator = gauge
            
        case (.counter, var counter as CounterAccumulator):
            counter.add(sample.value, at: sample.timestamp)
            accumulator = counter
            
        case (.histogram, var histogram as HistogramAccumulator),
             (.timer, var histogram as HistogramAccumulator):
            histogram.add(sample.value, at: sample.timestamp)
            accumulator = histogram
            
        default:
            // Type mismatch - should not happen
            assertionFailure("Accumulator type mismatch")
        }
    }
    
    func statistics() -> MetricStatistics {
        switch accumulator {
        case let gauge as GaugeAccumulator:
            return .basic(gauge.statistics())
            
        case let counter as CounterAccumulator:
            return .counter(counter.statistics())
            
        case let histogram as HistogramAccumulator:
            return .histogram(histogram.statistics())
            
        default:
            return .basic(.init())
        }
    }
    
    var sampleCount: Int {
        accumulator.sampleCount
    }
}

// MARK: - Supporting Types

/// Statistics about the window manager.
public struct WindowStatistics: Sendable {
    public let metricCount: Int
    public let totalWindows: Int
    public let totalDataPoints: Int
    public let windowDurations: Set<TimeInterval>
}

// MARK: - Extensions

fileprivate extension ClosedRange where Bound == Date {
    /// Checks if this range overlaps with another.
    func overlaps(_ other: ClosedRange<Date>) -> Bool {
        return lowerBound <= other.upperBound && upperBound >= other.lowerBound
    }
}
