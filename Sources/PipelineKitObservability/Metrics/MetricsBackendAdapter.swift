import Foundation
import PipelineKitCore

/// Adapter that bridges between MetricsCollector and MetricsBackend protocols
///
/// This allows using a MetricsCollector implementation as a MetricsBackend
/// for the MetricsObserver.
public actor MetricsBackendAdapter: MetricsBackend {
    private let collector: any MetricsCollector
    
    public init(collector: any MetricsCollector) {
        self.collector = collector
    }
    
    public func recordCounter(name: String, tags: [String: String]) async {
        await collector.recordCounter(name, value: 1.0, tags: tags)
    }
    
    public func recordGauge(name: String, value: Double, tags: [String: String]) async {
        await collector.recordGauge(name, value: value, tags: tags)
    }
    
    public func recordHistogram(name: String, value: Double, tags: [String: String]) async {
        await collector.recordHistogram(name, value: value, tags: tags)
    }
}

/// Convenience extension to create MetricsObserver with a MetricsCollector
public extension MetricsObserver {
    /// Creates a MetricsObserver using a MetricsCollector
    static func withCollector(
        _ collector: any MetricsCollector,
        configuration: Configuration = Configuration()
    ) async -> MetricsObserver {
        let adapter = MetricsBackendAdapter(collector: collector)
        return MetricsObserver(backend: adapter, configuration: configuration)
    }
}