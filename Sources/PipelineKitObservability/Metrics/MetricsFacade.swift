import Foundation

/// Global metrics facade for convenient access.
///
/// Provides a simple API for recording metrics without needing to
/// manage storage and exporters directly.
public enum Metrics {
    /// Shared storage for metrics.
    nonisolated(unsafe) public static var storage = MetricsStorage()
    
    /// Default StatsD exporter (mutable for runtime configuration).
    nonisolated(unsafe) public static var exporter: any MetricRecorder = StatsDExporter(configuration: .default)
    
    /// Error handler for metric failures.
    nonisolated(unsafe) public static var errorHandler: (@Sendable (Error) -> Void)?
    
    /// Configures the metrics system with a new exporter.
    ///
    /// This actually replaces the static exporter, fixing the configuration issue.
    public static func configure(
        host: String = "localhost",
        port: Int = 8125,
        prefix: String? = nil,
        globalTags: [String: String] = [:],
        maxBatchSize: Int = 20,
        flushInterval: TimeInterval = 0.1,
        sampleRate: Double = 1.0,
        sampleRatesByType: [String: Double] = [:],
        criticalPatterns: [String] = ["error", "timeout", "failure", "fatal", "panic"]
    ) async {
        let config = StatsDExporter.Configuration(
            host: host,
            port: port,
            prefix: prefix,
            globalTags: globalTags,
            maxBatchSize: maxBatchSize,
            flushInterval: flushInterval,
            sampleRate: sampleRate,
            sampleRatesByType: sampleRatesByType,
            criticalPatterns: criticalPatterns
        )
        
        let newExporter = await StatsDExporter(configuration: config)
        
        // Set up error handling
        if let handler = errorHandler {
            await newExporter.setErrorHandler(handler)
        }
        
        // Replace the static exporter
        exporter = newExporter
    }
    
    /// Configures the metrics system with a custom exporter.
    public static func configure(with customExporter: any MetricRecorder) {
        exporter = customExporter
    }
    
    /// Records a counter metric.
    public static func counter(
        _ name: String,
        value: Double = 1.0,
        tags: [String: String] = [:]
    ) async {
        let snapshot = MetricSnapshot.counter(name, value: value, tags: tags)
        await storage.record(snapshot)
        await exporter.record(snapshot)
    }
    
    /// Records a gauge metric.
    public static func gauge(
        _ name: String,
        value: Double,
        tags: [String: String] = [:],
        unit: String? = nil
    ) async {
        let snapshot = MetricSnapshot.gauge(name, value: value, tags: tags, unit: unit)
        await storage.record(snapshot)
        await exporter.record(snapshot)
    }
    
    /// Records a timer metric.
    public static func timer(
        _ name: String,
        duration: TimeInterval,
        tags: [String: String] = [:]
    ) async {
        let snapshot = MetricSnapshot.timer(name, duration: duration, tags: tags)
        await storage.record(snapshot)
        await exporter.record(snapshot)
    }
    
    /// Times a block of code using ContinuousClock for accuracy.
    public static func time<T: Sendable>(
        _ name: String,
        tags: [String: String] = [:],
        block: () async throws -> T
    ) async rethrows -> T {
        let start = ContinuousClock.now
        do {
            let result = try await block()
            let elapsed = ContinuousClock.now - start
            let duration = Double(elapsed.components.seconds) +
                           Double(elapsed.components.attoseconds) / 1e18
            await timer(name, duration: duration, tags: tags)
            return result
        } catch {
            // Record timer even on error
            let elapsed = ContinuousClock.now - start
            let duration = Double(elapsed.components.seconds) +
                           Double(elapsed.components.attoseconds) / 1e18
            await timer(name, duration: duration, tags: tags)
            throw error
        }
    }
    
    /// Disables metrics export (useful for testing).
    public static func disable() {
        exporter = NoOpRecorder()
    }
    
    /// Flushes any buffered metrics.
    public static func flush() async {
        // Flush storage if needed
        let snapshots = await storage.drain()
        for snapshot in snapshots {
            await exporter.record(snapshot)
        }
        
        // If exporter supports flushing, do it
        if let flushable = exporter as? StatsDExporter {
            await flushable.forceFlush()
        }
    }
}

// MARK: - No-Op Recorder

/// A no-op recorder that discards all metrics (useful for testing).
private struct NoOpRecorder: MetricRecorder, Sendable {
    func record(_ snapshot: MetricSnapshot) async {
        // Do nothing
    }
}
