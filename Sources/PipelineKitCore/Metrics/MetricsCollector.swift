import Foundation

/// Protocol for collecting metrics during pipeline execution.
public protocol MetricsCollector: Sendable {
    /// Records a counter metric.
    func recordCounter(_ name: String, value: Double, tags: [String: String]) async
    
    /// Records a gauge metric.
    func recordGauge(_ name: String, value: Double, tags: [String: String]) async
    
    /// Records a timer metric.
    func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async
    
    /// Records a histogram metric.
    func recordHistogram(_ name: String, value: Double, tags: [String: String]) async
}

/// Default implementation that delegates to the global Metrics facade.
public struct DefaultMetricsCollector: MetricsCollector {
    public init() {}
    
    public func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
        // This will be integrated with PipelineKitObservability.Metrics
        // For now, no-op to avoid circular dependency
    }
    
    public func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        // This will be integrated with PipelineKitObservability.Metrics
    }
    
    public func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        // This will be integrated with PipelineKitObservability.Metrics
    }
    
    public func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        // This will be integrated with PipelineKitObservability.Metrics
    }
}