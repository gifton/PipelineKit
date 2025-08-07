import Foundation
import PipelineKitCore

/// A metrics collector that batches metrics before recording them to reduce overhead.
///
/// This collector wraps an underlying metrics collector and batches metrics updates
/// to improve performance in high-throughput scenarios. Metrics are automatically
/// flushed when the batch size is reached or after a configurable time interval.
public actor BatchedMetricsCollector: MetricsCollector {
    // MARK: - Configuration
    
    public struct BatchConfiguration: Sendable {
        /// Maximum number of metrics to batch before automatic flush
        public let maxBatchSize: Int
        
        /// Maximum time interval between flushes
        public let flushInterval: TimeInterval
        
        /// Whether to coalesce duplicate metrics in a batch
        public let coalesceDuplicates: Bool
        
        /// Whether to aggregate counters before flushing
        public let aggregateCounters: Bool
        
        /// Buffer overflow behavior
        public let overflowPolicy: OverflowPolicy
        
        public enum OverflowPolicy: Sendable {
            case dropOldest
            case dropNewest
            case flush
        }
        
        public init(
            maxBatchSize: Int = 1000,
            flushInterval: TimeInterval = 1.0,
            coalesceDuplicates: Bool = true,
            aggregateCounters: Bool = true,
            overflowPolicy: OverflowPolicy = .flush
        ) {
            self.maxBatchSize = maxBatchSize
            self.flushInterval = flushInterval
            self.coalesceDuplicates = coalesceDuplicates
            self.aggregateCounters = aggregateCounters
            self.overflowPolicy = overflowPolicy
        }
        
        /// Standard configuration for high-throughput scenarios
        public static let highThroughput = BatchConfiguration(
            maxBatchSize: 5000,
            flushInterval: 0.5,
            coalesceDuplicates: true,
            aggregateCounters: true,
            overflowPolicy: .flush
        )
        
        /// Configuration for low-latency requirements
        public static let lowLatency = BatchConfiguration(
            maxBatchSize: 100,
            flushInterval: 0.1,
            coalesceDuplicates: false,
            aggregateCounters: false,
            overflowPolicy: .flush
        )
    }
    
    // MARK: - Properties
    
    private let underlying: any MetricsCollector
    private let configuration: BatchConfiguration
    private var batch: [BatchedMetric] = []
    private var flushTask: Task<Void, Never>?
    private var lastFlush = Date()
    
    // For counter aggregation
    private var counterAggregates: [MetricKey: Double] = [:]
    
    // MARK: - Types
    
    private enum BatchedMetric {
        case counter(name: String, value: Double, tags: [String: String])
        case gauge(name: String, value: Double, tags: [String: String])
        case histogram(name: String, value: Double, tags: [String: String])
        case timer(name: String, duration: TimeInterval, tags: [String: String])
    }
    
    private struct MetricKey: Hashable {
        let name: String
        let tags: [String: String]
        
        init(name: String, tags: [String: String]) {
            self.name = name
            // Sort tags for consistent hashing
            self.tags = tags
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            // Hash sorted tags for consistency
            for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
        }
    }
    
    // MARK: - Initialization
    
    public init(
        underlying: any MetricsCollector,
        configuration: BatchConfiguration = .init()
    ) async {
        self.underlying = underlying
        self.configuration = configuration
        await startFlushTask()
    }
    
    deinit {
        flushTask?.cancel()
    }
    
    // MARK: - MetricsCollector Protocol
    
    public func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
        if configuration.aggregateCounters {
            // Aggregate counters in memory
            let key = MetricKey(name: name, tags: tags)
            counterAggregates[key, default: 0] += value
            
            // Check if we should flush based on aggregate count
            if counterAggregates.count >= configuration.maxBatchSize {
                await flush()
            }
        } else {
            // Add to batch
            await addToBatch(.counter(name: name, value: value, tags: tags))
        }
    }
    
    public func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        await addToBatch(.gauge(name: name, value: value, tags: tags))
    }
    
    public func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        await addToBatch(.histogram(name: name, value: value, tags: tags))
    }
    
    public func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        await addToBatch(.timer(name: name, duration: duration, tags: tags))
    }
    
    public func recordBatch(_ metrics: [(name: String, type: MetricType, value: Double, tags: [String: String])]) async {
        for metric in metrics {
            switch metric.type {
            case .counter:
                await recordCounter(metric.name, value: metric.value, tags: metric.tags)
            case .gauge:
                await recordGauge(metric.name, value: metric.value, tags: metric.tags)
            case .histogram:
                await recordHistogram(metric.name, value: metric.value, tags: metric.tags)
            case .timer:
                await recordTimer(metric.name, duration: metric.value, tags: metric.tags)
            }
        }
    }
    
    public func getMetrics() async -> [MetricDataPoint] {
        // Flush any pending metrics before returning
        await flush()
        return await underlying.getMetrics()
    }
    
    public func reset() async {
        batch.removeAll()
        counterAggregates.removeAll()
        lastFlush = Date()
        await underlying.reset()
    }
    
    // MARK: - Batching Methods
    
    private func addToBatch(_ metric: BatchedMetric) async {
        batch.append(metric)
        
        // Check batch size
        if batch.count >= configuration.maxBatchSize {
            switch configuration.overflowPolicy {
            case .dropOldest:
                batch.removeFirst()
            case .dropNewest:
                batch.removeLast()
            case .flush:
                await flush()
            }
        }
    }
    
    /// Flush all batched metrics to the underlying collector
    public func flush() async {
        // Flush counters if aggregating
        if configuration.aggregateCounters {
            for (key, value) in counterAggregates {
                await underlying.recordCounter(key.name, value: value, tags: key.tags)
            }
            counterAggregates.removeAll()
        }
        
        // Process batch
        if configuration.coalesceDuplicates {
            await flushCoalesced()
        } else {
            await flushDirect()
        }
        
        batch.removeAll()
        lastFlush = Date()
    }
    
    private func flushDirect() async {
        for metric in batch {
            switch metric {
            case .counter(let name, let value, let tags):
                await underlying.recordCounter(name, value: value, tags: tags)
            case .gauge(let name, let value, let tags):
                await underlying.recordGauge(name, value: value, tags: tags)
            case .histogram(let name, let value, let tags):
                await underlying.recordHistogram(name, value: value, tags: tags)
            case .timer(let name, let duration, let tags):
                await underlying.recordTimer(name, duration: duration, tags: tags)
            }
        }
    }
    
    private func flushCoalesced() async {
        // Group metrics by type and key
        var gauges: [MetricKey: Double] = [:]
        var histograms: [MetricKey: [Double]] = [:]
        var timers: [MetricKey: [TimeInterval]] = [:]
        
        for metric in batch {
            switch metric {
            case .counter(let name, let value, let tags):
                // Counters handled separately if aggregating
                if !configuration.aggregateCounters {
                    await underlying.recordCounter(name, value: value, tags: tags)
                }
                
            case .gauge(let name, let value, let tags):
                // For gauges, keep the latest value
                let key = MetricKey(name: name, tags: tags)
                gauges[key] = value
                
            case .histogram(let name, let value, let tags):
                // For histograms, collect all values
                let key = MetricKey(name: name, tags: tags)
                histograms[key, default: []].append(value)
                
            case .timer(let name, let duration, let tags):
                // For timers, collect all durations
                let key = MetricKey(name: name, tags: tags)
                timers[key, default: []].append(duration)
            }
        }
        
        // Flush coalesced metrics
        for (key, value) in gauges {
            await underlying.recordGauge(key.name, value: value, tags: key.tags)
        }
        
        for (key, values) in histograms {
            for value in values {
                await underlying.recordHistogram(key.name, value: value, tags: key.tags)
            }
        }
        
        for (key, durations) in timers {
            for duration in durations {
                await underlying.recordTimer(key.name, duration: duration, tags: key.tags)
            }
        }
    }
    
    private func startFlushTask() {
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(configuration.flushInterval * 1_000_000_000))
                
                // Only flush if there are pending metrics
                if !batch.isEmpty || !counterAggregates.isEmpty {
                    await flush()
                }
            }
        }
    }
}

// MARK: - Convenience Extensions

public extension BatchedMetricsCollector {
    /// Force an immediate flush of all batched metrics
    func forceFlush() async {
        await flush()
    }
    
    /// Get current batch size for monitoring
    var currentBatchSize: Int {
        get async {
            batch.count + counterAggregates.count
        }
    }
    
    /// Get time since last flush
    var timeSinceLastFlush: TimeInterval {
        get async {
            Date().timeIntervalSince(lastFlush)
        }
    }
}

// MARK: - MetricsCollector Extension

public extension MetricsCollector {
    /// Wrap this collector with batching behavior
    func batched(
        configuration: BatchedMetricsCollector.BatchConfiguration = .init()
    ) async -> BatchedMetricsCollector {
        await BatchedMetricsCollector(underlying: self, configuration: configuration)
    }
}