//
//  MetricsEmitter.swift
//  PipelineKit
//
//  Event emitter that converts events to metrics
//

import Foundation
import PipelineKitCore

/// An event emitter that converts events into metrics.
///
/// This emitter translates pipeline events into metrics that can be
/// collected by a MetricsCollector for monitoring and alerting.
///
/// ## Design Decisions
///
/// 1. **Event-to-metric mapping**: Automatic metric generation from events
/// 2. **Non-blocking**: Uses Task{} for async metric recording
/// 3. **Configurable mapping**: Can customize how events map to metrics
/// 4. **Tag enrichment**: Adds contextual tags from event properties
public struct MetricsEmitter: EventEmitter {
    /// The metrics collector to send metrics to
    private let collector: any MetricsCollector

    /// Optional custom mapping function
    private let customMapping: (@Sendable (PipelineEvent) -> [(name: String, type: MetricType, value: Double, tags: [String: String])])?

    /// Creates a new metrics emitter.
    ///
    /// - Parameters:
    ///   - collector: The metrics collector to use
    ///   - customMapping: Optional custom event-to-metric mapping
    public init(
        collector: any MetricsCollector,
        customMapping: (@Sendable (PipelineEvent) -> [(name: String, type: MetricType, value: Double, tags: [String: String])])? = nil
    ) {
        self.collector = collector
        self.customMapping = customMapping
    }

    public func emit(_ event: PipelineEvent) {
        Task {
            await recordMetrics(for: event)
        }
    }

    /// Records metrics for an event.
    private func recordMetrics(for event: PipelineEvent) async {
        // Use custom mapping if provided
        if let customMapping = customMapping {
            let metrics = customMapping(event)
            for metric in metrics {
                await emitMetricToCollector(
                    name: metric.name,
                    type: metric.type,
                    value: metric.value,
                    tags: metric.tags
                )
            }
            return
        }

        // Default mapping based on event name
        await recordDefaultMetrics(for: event)
    }

    /// Records default metrics based on event patterns.
    private func recordDefaultMetrics(for event: PipelineEvent) async {
        let baseTags = extractBaseTags(from: event)

        switch event.name {
        case PipelineEvent.Name.commandStarted:
            await collector.recordCounter(
                "pipeline.command.started",
                value: 1,
                tags: baseTags
            )

        case PipelineEvent.Name.commandCompleted:
            await collector.recordCounter(
                "pipeline.command.completed",
                value: 1,
                tags: baseTags
            )

            // Record duration if available
            if let duration = extractDuration(from: event) {
                await collector.recordTimer(
                    "pipeline.command.duration",
                    duration: duration,
                    tags: baseTags
                )
            }

        case PipelineEvent.Name.commandFailed:
            await collector.recordCounter(
                "pipeline.command.failed",
                value: 1,
                tags: enrichErrorTags(baseTags, from: event)
            )

        case PipelineEvent.Name.middlewareTimeout:
            await collector.recordCounter(
                "pipeline.middleware.timeout",
                value: 1,
                tags: baseTags
            )

        case PipelineEvent.Name.middlewareRetry:
            await collector.recordCounter(
                "pipeline.middleware.retry",
                value: 1,
                tags: enrichRetryTags(baseTags, from: event)
            )

        case PipelineEvent.Name.middlewareRateLimited:
            await collector.recordCounter(
                "pipeline.middleware.rate_limited",
                value: 1,
                tags: baseTags
            )

        case PipelineEvent.Name.middlewareCircuitOpen:
            await collector.recordCounter(
                "pipeline.middleware.circuit_open",
                value: 1,
                tags: baseTags
            )

        case PipelineEvent.Name.middlewareBackpressure:
            if let queueSize = event.properties["queueSize"]?.get(Int.self) {
                await collector.recordGauge(
                    "pipeline.middleware.backpressure.queue_size",
                    value: Double(queueSize),
                    tags: baseTags
                )
            }

            await collector.recordCounter(
                "pipeline.middleware.backpressure",
                value: 1,
                tags: baseTags
            )

        default:
            // Generic counter for all events
            await collector.recordCounter(
                "pipeline.events",
                value: 1,
                tags: mergeTags(baseTags, ["event": event.name])
            )
        }
    }

    /// Extracts base tags from an event.
    private func extractBaseTags(from event: PipelineEvent) -> [String: String] {
        var tags: [String: String] = [:]

        // Add command type if present
        if let commandType = event.properties["commandType"]?.get(String.self) {
            tags["command"] = commandType
        }

        // Add middleware name if present
        if let middleware = event.properties["middleware"]?.get(String.self) {
            tags["middleware"] = middleware
        }

        // Add user ID if present
        if let userID = event.properties["userID"]?.get(String.self) {
            tags["user_id"] = userID
        }

        return tags
    }

    /// Extracts duration from event properties.
    private func extractDuration(from event: PipelineEvent) -> TimeInterval? {
        if let duration = event.properties["duration"]?.get(TimeInterval.self) {
            return duration
        }
        if let duration = event.properties["duration"]?.get(Double.self) {
            return TimeInterval(duration)
        }
        return nil
    }

    /// Enriches tags with error information.
    private func enrichErrorTags(_ tags: [String: String], from event: PipelineEvent) -> [String: String] {
        var enrichedTags = tags

        if let errorType = event.properties["errorType"]?.get(String.self) {
            enrichedTags["error_type"] = errorType
        }

        return enrichedTags
    }

    /// Enriches tags with retry information.
    private func enrichRetryTags(_ tags: [String: String], from event: PipelineEvent) -> [String: String] {
        var enrichedTags = tags

        if let attempt = event.properties["attempt"]?.get(Int.self) {
            enrichedTags["attempt"] = String(attempt)
        }

        if let maxAttempts = event.properties["maxAttempts"]?.get(Int.self) {
            enrichedTags["max_attempts"] = String(maxAttempts)
        }

        return enrichedTags
    }

    /// Merges two tag dictionaries.
    private func mergeTags(_ base: [String: String], _ additional: [String: String]) -> [String: String] {
        var merged = base
        for (key, value) in additional {
            merged[key] = value
        }
        return merged
    }

    /// Records a single metric.
    private func emitMetricToCollector(
        name: String,
        type: MetricType,
        value: Double,
        tags: [String: String]
    ) async {
        switch type {
        case .counter:
            await collector.recordCounter(name, value: value, tags: tags)
        case .gauge:
            await collector.recordGauge(name, value: value, tags: tags)
        case .histogram:
            await collector.recordHistogram(name, value: value, tags: tags)
        case .timer:
            await collector.recordTimer(name, duration: value, tags: tags)
        }
    }
}

// MARK: - Builder Pattern

public extension MetricsEmitter {
    /// Creates a metrics emitter with custom metric mappings.
    ///
    /// - Parameter builder: Closure to build custom mappings
    /// - Returns: Configured metrics emitter
    static func custom(
        collector: any MetricsCollector,
        builder: @escaping @Sendable (PipelineEvent) -> [(name: String, type: MetricType, value: Double, tags: [String: String])]
    ) -> MetricsEmitter {
        MetricsEmitter(collector: collector, customMapping: builder)
    }

    /// Creates a metrics emitter for performance monitoring.
    static func performance(collector: any MetricsCollector) -> MetricsEmitter {
        MetricsEmitter(collector: collector) { event in
            var metrics: [(name: String, type: MetricType, value: Double, tags: [String: String])] = []
            let tags = ["event": event.name]

            // Always record event occurrence
            metrics.append((
                name: "pipeline.events",
                type: .counter,
                value: 1,
                tags: tags
            ))

            // Record duration for completed events
            if let duration = event.properties["duration"]?.get(Double.self) {
                metrics.append((
                    name: "pipeline.duration",
                    type: .timer,
                    value: duration,
                    tags: tags
                ))
            }

            // Record queue sizes
            if let queueSize = event.properties["queueSize"]?.get(Int.self) {
                metrics.append((
                    name: "pipeline.queue.size",
                    type: .gauge,
                    value: Double(queueSize),
                    tags: tags
                ))
            }

            return metrics
        }
    }
}
