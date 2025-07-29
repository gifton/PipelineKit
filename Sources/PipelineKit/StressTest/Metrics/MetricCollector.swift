import Foundation

/// Central metric collection engine that manages buffers, aggregation, and export.
///
/// The MetricCollector is the main entry point for the metrics system. It:
/// - Manages per-metric buffers through MetricBufferPool
/// - Performs periodic collection from buffers
/// - Aggregates metrics over time windows
/// - Streams metrics to consumers
/// - Exports metrics in various formats
///
/// ## Usage Example
/// ```swift
/// let collector = MetricCollector()
/// await collector.start()
///
/// // Record metrics
/// await collector.record(.gauge("cpu.usage", value: 75.0))
/// await collector.record(.counter("requests.total", value: 1.0))
///
/// // Stream metrics
/// for await sample in await collector.stream() {
///     print("\(sample.name): \(sample.value)")
/// }
/// ```
public actor MetricCollector {
    /// Collection configuration.
    public struct Configuration: Sendable {
        /// How often to collect from buffers (seconds).
        public let collectionInterval: TimeInterval
        
        /// Maximum samples to collect per metric per interval.
        public let batchSize: Int
        
        /// Default buffer capacity for new metrics.
        public let defaultBufferCapacity: Int
        
        /// Whether to automatically start collection on init.
        public let autoStart: Bool
        
        public init(
            collectionInterval: TimeInterval = 1.0,
            batchSize: Int = 1000,
            defaultBufferCapacity: Int = 8192,
            autoStart: Bool = false
        ) {
            self.collectionInterval = collectionInterval
            self.batchSize = batchSize
            self.defaultBufferCapacity = defaultBufferCapacity
            self.autoStart = autoStart
        }
    }
    
    /// Current collector state.
    public enum State: String, Sendable {
        case idle
        case collecting
        case stopped
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    private let bufferPool: MetricBufferPool
    private var state: State = .idle
    private var collectionTask: Task<Void, Never>?
    
    /// Stream of collected metrics.
    private var metricStream: AsyncStream<MetricDataPoint>?
    private var metricContinuation: AsyncStream<MetricDataPoint>.Continuation?
    
    /// The main aggregator for metrics.
    private var aggregator: MetricAggregator?
    
    /// Export handlers.
    private var exporters: [any MetricExporter] = []
    
    /// Collection statistics.
    private var totalCollected: Int = 0
    private var lastCollectionTime: Date?
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.bufferPool = MetricBufferPool(defaultCapacity: configuration.defaultBufferCapacity)
        
        // Create integrated aggregator
        self.aggregator = MetricAggregator(
            configuration: MetricAggregator.Configuration(
                windows: [60, 300, 900], // 1min, 5min, 15min
                autoStart: configuration.autoStart
            )
        )
        
        if configuration.autoStart {
            Task {
                await self.start()
            }
        }
    }
    
    // MARK: - Public API
    
    /// Records a metric sample.
    public func record(_ sample: MetricDataPoint) async {
        let buffer = await bufferPool.buffer(for: sample.name)
        buffer.write(sample)
    }
    
    /// Records multiple metric samples.
    public func recordBatch(_ samples: [MetricDataPoint]) async {
        // Group by metric name for efficient buffer access
        let grouped = Dictionary(grouping: samples) { $0.name }
        
        for (metric, metricSamples) in grouped {
            let buffer = await bufferPool.buffer(for: metric)
            for sample in metricSamples {
                buffer.write(sample)
            }
        }
    }
    
    /// Starts the collection process.
    public func start() async {
        guard state == .idle else { return }
        
        state = .collecting
        
        // Start aggregator
        await aggregator?.start()
        
        // Create the stream
        let (stream, continuation) = AsyncStream<MetricDataPoint>.makeStream()
        self.metricStream = stream
        self.metricContinuation = continuation
        
        // Start collection task
        collectionTask = Task {
            await runCollectionLoop()
        }
    }
    
    /// Stops the collection process.
    public func stop() async {
        state = .stopped
        collectionTask?.cancel()
        collectionTask = nil
        metricContinuation?.finish()
        metricContinuation = nil
        
        // Stop aggregator
        await aggregator?.stop()
    }
    
    /// Returns a stream of collected metrics.
    public func stream() -> AsyncStream<MetricDataPoint> {
        if metricStream == nil {
            // Create a new stream if needed
            let (stream, continuation) = AsyncStream<MetricDataPoint>.makeStream()
            self.metricStream = stream
            self.metricContinuation = continuation
        }
        return metricStream!
    }
    
    /// Adds an exporter for metrics.
    public func addExporter(_ exporter: any MetricExporter) {
        exporters.append(exporter)
    }
    
    /// Returns current collection statistics.
    public func statistics() async -> CollectionStatistics {
        let bufferStats = await bufferPool.allStatistics()
        let aggregatorStats = await aggregator?.statistics()
        
        return CollectionStatistics(
            state: state,
            totalCollected: totalCollected,
            lastCollectionTime: lastCollectionTime,
            bufferStatistics: bufferStats,
            aggregatorCount: aggregatorStats?.metricCount ?? 0,
            exporterCount: exporters.count
        )
    }
    
    /// Forces an immediate collection cycle.
    public func collect() async {
        await performCollection()
    }
    
    // MARK: - Private Methods
    
    private func runCollectionLoop() async {
        while state == .collecting {
            await performCollection()
            
            // Sleep until next collection
            try? await Task.sleep(nanoseconds: UInt64(configuration.collectionInterval * 1_000_000_000))
        }
    }
    
    private func performCollection() async {
        lastCollectionTime = Date()
        
        // Get all buffer statistics
        let bufferStats = await bufferPool.allStatistics()
        
        // Collect from each buffer
        for (metric, stats) in bufferStats {
            if stats.used > 0 {
                let buffer = await bufferPool.buffer(for: metric)
                let samples = buffer.readBatch(maxCount: configuration.batchSize)
                
                // Process collected samples
                for sample in samples {
                    // Send to stream
                    metricContinuation?.yield(sample)
                    
                    // Update aggregator
                    await aggregator?.add(sample)
                    
                    // Send to exporters
                    for exporter in exporters {
                        await exporter.export(sample)
                    }
                    
                    totalCollected += 1
                }
            }
        }
    }
    
    /// Queries aggregated metrics.
    public func query(_ query: MetricQuery) async -> MetricQueryResult? {
        await aggregator?.query(query)
    }
    
    /// Gets the integrated aggregator.
    public func getAggregator() -> MetricAggregator? {
        aggregator
    }
}

// MARK: - Supporting Types

/// Statistics about the collection process.
public struct CollectionStatistics: Sendable {
    public let state: MetricCollector.State
    public let totalCollected: Int
    public let lastCollectionTime: Date?
    public let bufferStatistics: [String: BufferStatistics]
    public let aggregatorCount: Int
    public let exporterCount: Int
}

/// Protocol for metric exporters.
public protocol MetricExporter: Sendable {
    func export(_ sample: MetricDataPoint) async
    func flush() async
}

