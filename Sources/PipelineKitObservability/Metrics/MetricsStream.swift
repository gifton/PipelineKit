import PipelineKitCore
import Foundation

/// Provides real-time streaming capabilities for metrics with support for subscriptions and filtering.
///
/// This actor enables:
/// - Real-time metric streaming to subscribers
/// - Metric filtering and transformation
/// - Window-based aggregation streams
/// - Back-pressure handling
public actor MetricsStream {
    private let collector: any MetricsCollector
    private var subscribers: [UUID: Subscriber] = [:]
    private var streamTask: Task<Void, Never>?
    private let configuration: Configuration
    
    public struct Configuration: Sendable {
        /// Polling interval for metrics updates
        public let pollingInterval: TimeInterval
        
        /// Maximum subscribers allowed
        public let maxSubscribers: Int
        
        /// Buffer size for each subscriber
        public let subscriberBufferSize: Int
        
        /// Whether to deduplicate metrics
        public let deduplicateMetrics: Bool
        
        public init(
            pollingInterval: TimeInterval = 1.0,
            maxSubscribers: Int = 100,
            subscriberBufferSize: Int = 1000,
            deduplicateMetrics: Bool = true
        ) {
            self.pollingInterval = pollingInterval
            self.maxSubscribers = maxSubscribers
            self.subscriberBufferSize = subscriberBufferSize
            self.deduplicateMetrics = deduplicateMetrics
        }
    }
    
    private struct Subscriber {
        let id: UUID
        let filter: MetricFilter?
        let transform: MetricTransform?
        let continuation: AsyncStream<MetricUpdate>.Continuation
        var buffer: [MetricUpdate] = []
        let bufferSize: Int
    }
    
    // MARK: - Initialization
    
    public init(
        collector: any MetricsCollector,
        configuration: Configuration = Configuration()
    ) async {
        self.collector = collector
        self.configuration = configuration
        await startStreaming()
    }
    
    deinit {
        streamTask?.cancel()
    }
    
    // MARK: - Subscription Management
    
    /// Subscribe to metrics stream with optional filtering and transformation
    public func subscribe(
        filter: MetricFilter? = nil,
        transform: MetricTransform? = nil
    ) -> AsyncStream<MetricUpdate> {
        let id = UUID()
        
        return AsyncStream { continuation in
            Task {
                await self.addSubscriber(
                    id: id,
                    filter: filter,
                    transform: transform,
                    continuation: continuation
                )
            }
            
            continuation.onTermination = { _ in
                Task {
                    await self.removeSubscriber(id: id)
                }
            }
        }
    }
    
    private func addSubscriber(
        id: UUID,
        filter: MetricFilter?,
        transform: MetricTransform?,
        continuation: AsyncStream<MetricUpdate>.Continuation
    ) {
        guard subscribers.count < configuration.maxSubscribers else {
            continuation.finish()
            return
        }
        
        subscribers[id] = Subscriber(
            id: id,
            filter: filter,
            transform: transform,
            continuation: continuation,
            bufferSize: configuration.subscriberBufferSize
        )
    }
    
    private func removeSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)
    }
    
    // MARK: - Streaming
    
    private func startStreaming() {
        streamTask = Task {
            var lastMetrics: Set<MetricIdentity> = []
            
            while !Task.isCancelled {
                // Get current metrics
                let currentMetrics = await collector.getMetrics()
                
                // Convert to updates
                let updates = createUpdates(
                    from: currentMetrics,
                    lastMetrics: configuration.deduplicateMetrics ? lastMetrics : []
                )
                
                // Distribute to subscribers
                await distributeUpdates(updates)
                
                // Update last metrics for deduplication
                if configuration.deduplicateMetrics {
                    lastMetrics = Set(currentMetrics.map { MetricIdentity(from: $0) })
                }
                
                // Sleep until next poll
                try? await Task.sleep(nanoseconds: UInt64(configuration.pollingInterval * 1_000_000_000))
            }
        }
    }
    
    private func createUpdates(
        from metrics: [MetricDataPoint],
        lastMetrics: Set<MetricIdentity>
    ) -> [MetricUpdate] {
        var updates: [MetricUpdate] = []
        
        for metric in metrics {
            let identity = MetricIdentity(from: metric)
            
            if lastMetrics.isEmpty || !lastMetrics.contains(identity) {
                updates.append(MetricUpdate(
                    metric: metric,
                    updateType: lastMetrics.isEmpty ? .initial : .new,
                    timestamp: Date()
                ))
            } else {
                // Metric exists, check if value changed
                updates.append(MetricUpdate(
                    metric: metric,
                    updateType: .updated,
                    timestamp: Date()
                ))
            }
        }
        
        return updates
    }
    
    private func distributeUpdates(_ updates: [MetricUpdate]) async {
        for (id, var subscriber) in subscribers {
            let filteredUpdates = applyFilters(updates, filter: subscriber.filter)
            let transformedUpdates = applyTransforms(filteredUpdates, transform: subscriber.transform)
            
            // Add to buffer
            subscriber.buffer.append(contentsOf: transformedUpdates)
            
            // Apply back-pressure if buffer is full
            if subscriber.buffer.count > subscriber.bufferSize {
                subscriber.buffer.removeFirst(subscriber.buffer.count - subscriber.bufferSize)
            }
            
            // Send buffered updates
            while !subscriber.buffer.isEmpty {
                let update = subscriber.buffer.removeFirst()
                subscriber.continuation.yield(update)
            }
            
            // Update subscriber
            subscribers[id] = subscriber
        }
    }
    
    private func applyFilters(_ updates: [MetricUpdate], filter: MetricFilter?) -> [MetricUpdate] {
        guard let filter = filter else { return updates }
        return updates.filter { filter.matches($0.metric) }
    }
    
    private func applyTransforms(_ updates: [MetricUpdate], transform: MetricTransform?) -> [MetricUpdate] {
        guard let transform = transform else { return updates }
        return updates.compactMap { transform.transform($0) }
    }
}

// MARK: - Stream Types

public struct MetricUpdate: Sendable {
    public let metric: MetricDataPoint
    public let updateType: UpdateType
    public let timestamp: Date
    
    public enum UpdateType: String, Sendable {
        case initial
        case new
        case updated
        case removed
    }
}

public struct MetricFilter: Sendable {
    private let predicate: @Sendable (MetricDataPoint) -> Bool
    
    public init(predicate: @escaping @Sendable (MetricDataPoint) -> Bool) {
        self.predicate = predicate
    }
    
    func matches(_ metric: MetricDataPoint) -> Bool {
        predicate(metric)
    }
    
    // Convenience filters
    public static func name(_ pattern: String) -> MetricFilter {
        MetricFilter { metric in
            if pattern.contains("*") {
                let regex = pattern.replacingOccurrences(of: "*", with: ".*")
                return metric.name.range(of: regex, options: .regularExpression) != nil
            }
            return metric.name == pattern
        }
    }
    
    public static func type(_ type: MetricType) -> MetricFilter {
        MetricFilter { $0.type == type }
    }
    
    public static func tag(_ key: String, value: String) -> MetricFilter {
        MetricFilter { $0.tags[key] == value }
    }
    
    public static func and(_ filters: MetricFilter...) -> MetricFilter {
        MetricFilter { metric in
            filters.allSatisfy { $0.matches(metric) }
        }
    }
    
    public static func or(_ filters: MetricFilter...) -> MetricFilter {
        MetricFilter { metric in
            filters.contains { $0.matches(metric) }
        }
    }
}

public struct MetricTransform: Sendable {
    private let transformer: @Sendable (MetricUpdate) -> MetricUpdate?
    
    public init(transformer: @escaping @Sendable (MetricUpdate) -> MetricUpdate?) {
        self.transformer = transformer
    }
    
    func transform(_ update: MetricUpdate) -> MetricUpdate? {
        transformer(update)
    }
    
    // Convenience transforms
    public static func scale(by factor: Double) -> MetricTransform {
        MetricTransform { update in
            var metric = update.metric
            metric = MetricDataPoint(
                name: metric.name,
                type: metric.type,
                value: metric.value * factor,
                timestamp: metric.timestamp,
                tags: metric.tags
            )
            return MetricUpdate(
                metric: metric,
                updateType: update.updateType,
                timestamp: update.timestamp
            )
        }
    }
    
    public static func addTag(key: String, value: String) -> MetricTransform {
        MetricTransform { update in
            var tags = update.metric.tags
            tags[key] = value
            
            let metric = MetricDataPoint(
                name: update.metric.name,
                type: update.metric.type,
                value: update.metric.value,
                timestamp: update.metric.timestamp,
                tags: tags
            )
            
            return MetricUpdate(
                metric: metric,
                updateType: update.updateType,
                timestamp: update.timestamp
            )
        }
    }
}

// MARK: - Window Aggregation

public extension MetricsStream {
    /// Creates a windowed aggregation stream
    func windowedStream(
        window: TimeInterval,
        aggregation: WindowAggregation,
        filter: MetricFilter? = nil
    ) -> AsyncStream<WindowedMetric> {
        let baseStream = subscribe(filter: filter, transform: nil)
        
        return AsyncStream { continuation in
            Task {
                var windowData: [String: [MetricDataPoint]] = [:]
                var windowStart = Date()
                
                for await update in baseStream {
                    let metric = update.metric
                    let key = "\(metric.name)_\(metric.tags.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))"
                    
                    if windowData[key] == nil {
                        windowData[key] = []
                    }
                    windowData[key]?.append(metric)
                    
                    // Check if window expired
                    if Date().timeIntervalSince(windowStart) >= window {
                        // Emit aggregated metrics
                        for (key, metrics) in windowData {
                            if let aggregated = aggregate(metrics: metrics, type: aggregation) {
                                continuation.yield(WindowedMetric(
                                    name: metrics.first?.name ?? "",
                                    value: aggregated,
                                    type: metrics.first?.type ?? .gauge,
                                    tags: metrics.first?.tags ?? [:],
                                    window: TimeWindow(
                                        duration: window,
                                        startTime: windowStart
                                    ),
                                    aggregationType: aggregation,
                                    sampleCount: metrics.count
                                ))
                            }
                        }
                        
                        // Reset window
                        windowData.removeAll()
                        windowStart = Date()
                    }
                }
                
                continuation.finish()
            }
        }
    }
    
    private func aggregate(metrics: [MetricDataPoint], type: WindowAggregation) -> Double? {
        guard !metrics.isEmpty else { return nil }
        
        let values = metrics.map { $0.value }
        
        switch type {
        case .sum:
            return values.reduce(0, +)
        case .average:
            return values.reduce(0, +) / Double(values.count)
        case .min:
            return values.min()
        case .max:
            return values.max()
        case .count:
            return Double(values.count)
        case .rate:
            guard metrics.count >= 2 else { return nil }
            let timeDiff = metrics.last!.timestamp.timeIntervalSince(metrics.first!.timestamp)
            return timeDiff > 0 ? Double(metrics.count) / timeDiff : nil
        }
    }
}

public enum WindowAggregation: String, Sendable {
    case sum
    case average
    case min
    case max
    case count
    case rate
}

public struct WindowedMetric: Sendable {
    public let name: String
    public let value: Double
    public let type: MetricType
    public let tags: [String: String]
    public let window: TimeWindow
    public let aggregationType: WindowAggregation
    public let sampleCount: Int
}

// MARK: - Helpers

private struct MetricIdentity: Hashable {
    let name: String
    let type: MetricType
    let tags: [String: String]
    
    init(from metric: MetricDataPoint) {
        self.name = metric.name
        self.type = metric.type
        self.tags = metric.tags
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(type)
        for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
            hasher.combine(key)
            hasher.combine(value)
        }
    }
}