import Foundation

/// Protocol for metrics collection
public protocol MetricsCollector: Sendable {
    func recordLatency(_ duration: TimeInterval, for operation: String, tags: [String: String]) async
    func incrementCounter(_ name: String, tags: [String: String]) async
    func recordGauge(_ value: Double, for name: String, tags: [String: String]) async
}

/// Standard in-memory metrics collector
public actor StandardMetricsCollector: MetricsCollector {
    public static let shared = StandardMetricsCollector()
    
    private var latencies: [String: [TimeInterval]] = [:]
    private var counters: [String: Int] = [:]
    private var gauges: [String: Double] = [:]
    
    private init() {}
    
    public func recordLatency(_ duration: TimeInterval, for operation: String, tags: [String: String]) {
        let key = makeKey(operation, tags: tags)
        if latencies[key] == nil {
            latencies[key] = []
        }
        latencies[key]?.append(duration)
        
        // Keep only last 1000 entries per metric
        if let count = latencies[key]?.count, count > 1000 {
            latencies[key]?.removeFirst(count - 1000)
        }
    }
    
    public func incrementCounter(_ name: String, tags: [String: String]) {
        let key = makeKey(name, tags: tags)
        counters[key, default: 0] += 1
    }
    
    public func recordGauge(_ value: Double, for name: String, tags: [String: String]) {
        let key = makeKey(name, tags: tags)
        gauges[key] = value
    }
    
    /// Get metric statistics
    public func getStats() -> MetricsSnapshot {
        MetricsSnapshot(
            latencies: latencies,
            counters: counters,
            gauges: gauges
        )
    }
    
    /// Reset all metrics
    public func reset() {
        latencies.removeAll()
        counters.removeAll()
        gauges.removeAll()
    }
    
    private func makeKey(_ name: String, tags: [String: String]) -> String {
        let sortedTags = tags.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        return sortedTags.isEmpty ? name : "\(name){\(sortedTags)}"
    }
}

/// Snapshot of current metrics
public struct MetricsSnapshot: Sendable {
    public let latencies: [String: [TimeInterval]]
    public let counters: [String: Int]
    public let gauges: [String: Double]
    
    /// Calculate percentiles for a latency metric
    public func percentiles(for metric: String, percentiles: [Double] = [0.5, 0.95, 0.99]) -> [Double: TimeInterval] {
        guard let values = latencies[metric], !values.isEmpty else { return [:] }
        
        let sorted = values.sorted()
        var result: [Double: TimeInterval] = [:]
        
        for p in percentiles {
            let index = Int(Double(sorted.count - 1) * p)
            result[p] = sorted[index]
        }
        
        return result
    }
}