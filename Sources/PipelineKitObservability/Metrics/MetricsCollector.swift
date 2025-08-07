import Foundation
import PipelineKitCore

// MARK: - MetricsCollector Extensions

/// Extended functionality for MetricsCollector protocol defined in Core.
///
/// This file provides additional implementations and utilities for the
/// MetricsCollector protocol. The protocol itself is defined in PipelineKitCore
/// to allow Core types to reference it without circular dependencies.

// MARK: - Default Implementations

public extension MetricsCollector {
    /// Default implementation that increments counter by 1.
    func incrementCounter(_ name: String, tags: [String: String] = [:]) async {
        await recordCounter(name, value: 1.0, tags: tags)
    }
    
    /// Retrieves all collected metrics.
    /// - Returns: An array of metric data points ready for export
    func getMetrics() async -> [MetricDataPoint] {
        // Default implementation returns empty array
        // Concrete implementations should override this
        return []
    }
}

// MARK: - Supporting Types

/// Represents a single metric data point with metadata.
public struct MetricDataPoint: Sendable, Codable {
    public let name: String
    public let type: MetricType
    public let value: Double
    public let timestamp: Date
    public let tags: [String: String]
    
    public init(name: String, type: MetricType, value: Double, timestamp: Date = Date(), tags: [String: String] = [:]) {
        self.name = name
        self.type = type
        self.value = value
        self.timestamp = timestamp
        self.tags = tags
    }
}