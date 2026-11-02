import Foundation
import Synchronization

/// Global metrics facade for convenient access.
///
/// Provides a simple API for recording metrics without needing to
/// manage storage and exporters directly.
public enum Metrics {
    /// One configuration generation. Referenced storage and exporters are not cloned;
    /// reusing a recorder intentionally shares its mutable state across generations.
    public struct Configuration: Sendable {
        public let storage: MetricsStorage
        public let exporter: any MetricRecorder
        /// Installed on StatsD exporters; custom recorders own their error reporting.
        public let errorHandler: (@Sendable (any Error) -> Void)?

        public init(
            storage: MetricsStorage,
            exporter: any MetricRecorder,
            errorHandler: (@Sendable (any Error) -> Void)? = nil
        ) {
            self.storage = storage
            self.exporter = exporter
            self.errorHandler = errorHandler
        }
    }

    private static let owner = MetricsConfigurationOwner()

    /// Returns the current complete configuration snapshot.
    public static var configuration: Configuration { owner.snapshot() }

    /// Prepares error reporting before publishing one complete configuration.
    /// Existing operations retain their snapshot; retired exporters are not closed.
    public static func configure(_ configuration: Configuration) async {
        if let statsD = configuration.exporter as? StatsDExporter {
            await statsD.setErrorHandler(configuration.errorHandler)
        }
        owner.replace(with: configuration)
    }
    
    /// Configures the metrics system with a new exporter.
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
        let previous = configuration
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
        
        let newExporter = StatsDExporter(configuration: config)
        
        await configure(Configuration(storage: previous.storage, exporter: newExporter,
                                      errorHandler: previous.errorHandler))
    }
    
    /// Configures the metrics system with a custom exporter.
    public static func configure(with customExporter: any MetricRecorder) async {
        let previous = configuration
        await configure(Configuration(storage: previous.storage, exporter: customExporter,
                                      errorHandler: previous.errorHandler))
    }
    
    /// Records a counter metric.
    public static func counter(
        _ name: String,
        value: Double = 1.0,
        tags: [String: String] = [:]
    ) async {
        let snapshot = MetricSnapshot.counter(name, value: value, tags: tags)
        await record(snapshot)
    }
    
    /// Records a gauge metric.
    public static func gauge(
        _ name: String,
        value: Double,
        tags: [String: String] = [:],
        unit: String? = nil
    ) async {
        let snapshot = MetricSnapshot.gauge(name, value: value, tags: tags, unit: unit)
        await record(snapshot)
    }
    
    /// Records a timer metric.
    public static func timer(
        _ name: String,
        duration: TimeInterval,
        tags: [String: String] = [:]
    ) async {
        let snapshot = MetricSnapshot.timer(name, duration: duration, tags: tags)
        await record(snapshot)
    }

    internal static func record(
        _ snapshot: MetricSnapshot,
        afterStorage: (@Sendable () async -> Void)? = nil
    ) async {
        let captured = configuration
        // Keep every capture alive until the operation settles, including callback
        // captures unused by custom recorders. Covered by
        // testConfigurationCallbacksCanReenterAndRelease.
        defer { withExtendedLifetime(captured) {} }
        await captured.storage.record(snapshot)
        await afterStorage?()
        await captured.exporter.record(snapshot)
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
        owner.disable()
    }
    
    /// Drains the captured local storage and flushes its exporter without replaying records.
    /// This is not a barrier for concurrent records and does not flush retired exporters.
    public static func flush() async {
        let captured = configuration
        defer { withExtendedLifetime(captured) {} }
        _ = await captured.storage.drain()
        if let flushable = captured.exporter as? any FlushableMetricRecorder {
            await flushable.flush()
        }
    }
}

private final class MetricsConfigurationOwner: Sendable {
    private let state = Mutex(Metrics.Configuration(
        storage: MetricsStorage(), exporter: StatsDExporter(configuration: .default)
    ))

    func snapshot() -> Metrics.Configuration { state.withLock { $0 } }

    func replace(with configuration: Metrics.Configuration) {
        let retired = state.withLock { current in
            let retired = current
            current = configuration
            return retired
        }
        // Final releases can reenter configuration. Keep all retired captures past
        // unlock; testReplacingOrDisablingLastOwnedExporterReleasesOutsideLock.
        withExtendedLifetime(retired) {}
    }

    func disable() {
        let retired = state.withLock { current in
            let retired = current
            current = Metrics.Configuration(storage: current.storage, exporter: NoOpRecorder(),
                                            errorHandler: current.errorHandler)
            return retired
        }
        withExtendedLifetime(retired) {}
    }
}

// MARK: - No-Op Recorder

/// A no-op recorder that discards all metrics (useful for testing).
private struct NoOpRecorder: MetricRecorder, Sendable {
    func record(_ snapshot: MetricSnapshot) async {
        // Do nothing
    }
}
