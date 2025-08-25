import Foundation

/// Pre-aggregation support for reducing network traffic.
/// Combines multiple metric updates locally before sending.
public struct AggregationConfiguration: Sendable {
    /// Enable metric aggregation (opt-in for backward compatibility)
    public let enabled: Bool
    
    /// How often to flush aggregated metrics (seconds)
    public let flushInterval: TimeInterval
    
    /// Maximum unique metric keys to store
    public let maxUniqueMetrics: Int
    
    /// Maximum total values across all timers/histograms
    public let maxTotalValues: Int
    
    /// Jitter percentage for flush timing (0.0-0.2)
    public let flushJitter: Double
    
    public init(
        enabled: Bool = false,
        flushInterval: TimeInterval = 10.0,
        maxUniqueMetrics: Int = 1000,
        maxTotalValues: Int = 10000,
        flushJitter: Double = 0.1
    ) {
        self.enabled = enabled
        self.flushInterval = flushInterval
        self.maxUniqueMetrics = maxUniqueMetrics
        self.maxTotalValues = maxTotalValues
        self.flushJitter = min(0.2, max(0.0, flushJitter))
    }
}

/// Key for metric deduplication with canonical tag ordering.
struct MetricKey: Hashable, Sendable {
    let name: String
    let canonicalTags: String  // Pre-sorted "k1:v1,k2:v2" format
    
    init(name: String, tags: [String: String]) {
        self.name = name
        // Canonicalize tags to ensure consistent hashing
        if tags.isEmpty {
            self.canonicalTags = ""
        } else {
            self.canonicalTags = tags
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        }
    }
}

/// Aggregated metric data.
enum AggregatedMetric: Sendable {
    case counter(sum: Double)  // Already scaled by sample rate
    case gauge(latest: Double)
    case timer(values: [Double])
    case histogram(values: [Double])
    
    /// Count of values stored (for memory tracking).
    var valueCount: Int {
        switch self {
        case .counter, .gauge:
            return 1
        case .timer(let values), .histogram(let values):
            return values.count
        }
    }
}

/// Thread-safe metric aggregator.
actor MetricAggregator {
    private let configuration: AggregationConfiguration
    private var buffer: [MetricKey: AggregatedMetric] = [:]
    private var totalValueCount = 0
    private var flushTask: Task<Void, Never>?
    private var warningsEmitted = Set<String>()
    
    init(configuration: AggregationConfiguration) {
        self.configuration = configuration
    }
    
    deinit {
        flushTask?.cancel()
    }
    
    /// Aggregates a metric snapshot.
    /// - Parameters:
    ///   - snapshot: The metric to aggregate
    ///   - sampleRate: The sample rate (metrics are pre-scaled)
    /// - Returns: Whether aggregation succeeded (false = buffer full)
    func aggregate(_ snapshot: MetricSnapshot, sampleRate: Double) async -> Bool {
        // Check limits
        guard buffer.count < configuration.maxUniqueMetrics || 
              buffer.keys.contains(MetricKey(name: snapshot.name, tags: snapshot.tags)) else {
            await emitWarningOnce("aggregation_keys_limit", 
                                 "Aggregation buffer reached \(configuration.maxUniqueMetrics) unique keys")
            return false
        }
        
        guard totalValueCount < configuration.maxTotalValues else {
            await emitWarningOnce("aggregation_values_limit",
                                 "Aggregation buffer reached \(configuration.maxTotalValues) total values")
            return false
        }
        
        let key = MetricKey(name: snapshot.name, tags: snapshot.tags)
        
        // Pre-scale counters by sample rate for accuracy
        let value: Double
        if snapshot.type == "counter" && sampleRate < 1.0 {
            value = (snapshot.value ?? 1.0) / sampleRate
        } else {
            value = snapshot.value ?? 1.0
        }
        
        // Update value count
        if let existing = buffer[key] {
            totalValueCount -= existing.valueCount
        }
        
        // Type-specific aggregation
        switch snapshot.type {
        case "counter":
            if case .counter(let sum) = buffer[key] {
                buffer[key] = .counter(sum: sum + value)
            } else {
                buffer[key] = .counter(sum: value)
            }
            totalValueCount += 1
            
        case "gauge":
            buffer[key] = .gauge(latest: value)
            totalValueCount += 1
            
        case "timer":
            if case .timer(var values) = buffer[key] {
                values.append(value)
                buffer[key] = .timer(values: values)
                totalValueCount += values.count
            } else {
                buffer[key] = .timer(values: [value])
                totalValueCount += 1
            }
            
        case "histogram":
            if case .histogram(var values) = buffer[key] {
                values.append(value)
                buffer[key] = .histogram(values: values)
                totalValueCount += values.count
            } else {
                buffer[key] = .histogram(values: [value])
                totalValueCount += 1
            }
            
        default:
            // Unknown type, treat as gauge
            buffer[key] = .gauge(latest: value)
            totalValueCount += 1
        }
        
        // Start flush timer if needed
        if flushTask == nil {
            flushTask = Task { [weak self] in
                guard let self = self else { return }
                
                // Add jitter to prevent thundering herd
                let jitter = Double.random(in: -configuration.flushJitter...configuration.flushJitter)
                let sleepTime = configuration.flushInterval * (1.0 + jitter)
                
                try? await Task.sleep(for: .seconds(sleepTime))
                _ = await self.flush()
            }
        }
        
        return true
    }
    
    /// Flushes all aggregated metrics.
    /// - Returns: Array of formatted metric lines ready to send
    func flush() async -> [(snapshot: MetricSnapshot, sampleRate: Double)] {
        guard !buffer.isEmpty else { return [] }
        
        var results: [(MetricSnapshot, Double)] = []
        
        for (key, metric) in buffer {
            // Reconstruct tags from canonical string
            let tags = parseCanonicalTags(key.canonicalTags)
            
            switch metric {
            case .counter(let sum):
                // Counters already scaled, send with @1
                let snapshot = MetricSnapshot(
                    name: key.name,
                    type: "counter",
                    value: sum,
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    tags: tags,
                    unit: nil
                )
                results.append((snapshot, 1.0))
                
            case .gauge(let latest):
                let snapshot = MetricSnapshot(
                    name: key.name,
                    type: "gauge",
                    value: latest,
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    tags: tags,
                    unit: nil
                )
                results.append((snapshot, 1.0))
                
            case .timer(let values):
                // Send each timer value individually (preserves fidelity)
                for value in values {
                    let snapshot = MetricSnapshot(
                        name: key.name,
                        type: "timer",
                        value: value,
                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                        tags: tags,
                        unit: nil
                    )
                    results.append((snapshot, 1.0))
                }
                
            case .histogram(let values):
                // Send each histogram value individually
                for value in values {
                    let snapshot = MetricSnapshot(
                        name: key.name,
                        type: "histogram",
                        value: value,
                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                        tags: tags,
                        unit: nil
                    )
                    results.append((snapshot, 1.0))
                }
            }
        }
        
        // Clear buffer
        buffer.removeAll(keepingCapacity: true)
        totalValueCount = 0
        flushTask = nil
        
        return results
    }
    
    /// Forces an immediate flush if aggregation is in progress.
    func forceFlush() async -> [(MetricSnapshot, Double)] {
        flushTask?.cancel()
        flushTask = nil
        return await flush()
    }
    
    // MARK: - Private Helpers
    
    private func parseCanonicalTags(_ canonical: String) -> [String: String] {
        guard !canonical.isEmpty else { return [:] }
        
        var tags: [String: String] = [:]
        for pair in canonical.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                tags[String(parts[0])] = String(parts[1])
            }
        }
        return tags
    }
    
    private func emitWarningOnce(_ key: String, _ message: String) async {
        guard !warningsEmitted.contains(key) else { return }
        warningsEmitted.insert(key)
        #if DEBUG
        print("[MetricAggregator] Warning: \(message)")
        #endif
    }
}
