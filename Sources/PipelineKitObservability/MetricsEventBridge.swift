//
//  MetricsEventBridge.swift
//  PipelineKit
//
//  Automatic event-to-metric conversion with natural integration
//

import Foundation
import PipelineKitCore

/// Configuration for automatic event-to-metric conversion.
public struct MetricsGenerationConfig: Sendable {
    /// Enable automatic metric generation from events
    public let enabled: Bool
    
    /// Generate duration metrics from completed events
    public let recordDurations: Bool
    
    /// Generate counter metrics for all events
    public let recordCounts: Bool
    
    /// Generate error rate metrics
    public let recordErrors: Bool
    
    /// Patterns to always generate metrics for
    public let includePatterns: [String]
    
    /// Patterns to never generate metrics for
    public let excludePatterns: [String]
    
    /// Default configuration with sensible defaults
    public static let `default` = MetricsGenerationConfig(
        enabled: true,
        recordDurations: true,
        recordCounts: true,
        recordErrors: true,
        includePatterns: [],
        excludePatterns: ["debug", "trace"]
    )
    
    /// Minimal configuration for production
    public static let production = MetricsGenerationConfig(
        enabled: true,
        recordDurations: true,
        recordCounts: false,  // Don't count everything
        recordErrors: true,
        includePatterns: ["command", "middleware"],
        excludePatterns: ["debug", "trace", "heartbeat"]
    )
    
    public init(
        enabled: Bool = true,
        recordDurations: Bool = true,
        recordCounts: Bool = true,
        recordErrors: Bool = true,
        includePatterns: [String] = [],
        excludePatterns: [String] = []
    ) {
        self.enabled = enabled
        self.recordDurations = recordDurations
        self.recordCounts = recordCounts
        self.recordErrors = recordErrors
        self.includePatterns = includePatterns
        self.excludePatterns = excludePatterns
    }
}

/// Automatically converts events to metrics based on patterns.
///
/// This bridge provides seamless integration between events and metrics,
/// generating appropriate metrics based on event naming conventions.
public final class MetricsEventBridge: EventSubscriber, Sendable {
    private let recorder: any MetricRecorder
    private let config: MetricsGenerationConfig
    
    /// Creates a new event-to-metrics bridge.
    ///
    /// - Parameters:
    ///   - recorder: The metric recorder to send metrics to
    ///   - config: Configuration for metric generation
    public init(
        recorder: any MetricRecorder,
        config: MetricsGenerationConfig = .default
    ) {
        self.recorder = recorder
        self.config = config
    }
    
    /// Processes an event and generates appropriate metrics.
    public func process(_ event: PipelineEvent) async {
        guard config.enabled else { return }
        
        // Check exclusion patterns first
        for pattern in config.excludePatterns {
            if event.name.contains(pattern) {
                return
            }
        }
        
        // Check inclusion patterns if specified
        if !config.includePatterns.isEmpty {
            var included = false
            for pattern in config.includePatterns {
                if event.name.contains(pattern) {
                    included = true
                    break
                }
            }
            if !included {
                return
            }
        }
        
        // Generate metrics based on event type
        await generateMetrics(for: event)
    }
    
    private func generateMetrics(for event: PipelineEvent) async {
        let tags = extractTags(from: event)
        
        // Handle specific event patterns
        switch event.name {
        case PipelineEvent.Name.commandCompleted:
            await handleCommandCompleted(event, tags: tags)
            
        case PipelineEvent.Name.commandFailed:
            await handleCommandFailed(event, tags: tags)
            
        case PipelineEvent.Name.middlewareCompleted:
            await handleMiddlewareCompleted(event, tags: tags)
            
        case PipelineEvent.Name.middlewareFailed:
            await handleMiddlewareFailed(event, tags: tags)
            
        case let name where name.contains(".completed"):
            await handleGenericCompleted(event, tags: tags)
            
        case let name where name.contains(".failed") || name.contains(".error"):
            await handleGenericError(event, tags: tags)
            
        default:
            // Generic counter for all events if configured
            if config.recordCounts {
                await recorder.record(.counter(
                    sanitizeMetricName(event.name),
                    tags: tags
                ))
            }
        }
    }
    
    private func handleCommandCompleted(_ event: PipelineEvent, tags: [String: String]) async {
        var tags = tags
        
        // Add command type if available
        if let commandType = event.properties["commandType"]?.get(String.self) {
            tags["command_type"] = sanitizeTagValue(commandType)
        }
        
        // Record duration if available
        if config.recordDurations,
           let duration = extractDuration(from: event) {
            await recorder.record(.timer(
                "command.duration",
                duration: duration,
                tags: tags
            ))
        }
        
        // Record completion count
        if config.recordCounts {
            await recorder.record(.counter(
                "command.completed",
                tags: tags
            ))
        }
    }
    
    private func handleCommandFailed(_ event: PipelineEvent, tags: [String: String]) async {
        var tags = tags
        
        // Add error information
        if let errorType = event.properties["errorType"]?.get(String.self) {
            tags["error_type"] = sanitizeTagValue(errorType)
        }
        
        if let commandType = event.properties["commandType"]?.get(String.self) {
            tags["command_type"] = sanitizeTagValue(commandType)
        }
        
        // Record error
        if config.recordErrors {
            await recorder.record(.counter(
                "command.error",
                tags: tags
            ))
        }
        
        // Record duration even for failures
        if config.recordDurations,
           let duration = extractDuration(from: event) {
            await recorder.record(.timer(
                "command.error.duration",
                duration: duration,
                tags: tags
            ))
        }
    }
    
    private func handleMiddlewareCompleted(_ event: PipelineEvent, tags: [String: String]) async {
        var tags = tags
        
        // Add middleware name
        if let middleware = event.properties["middleware"]?.get(String.self) {
            tags["middleware"] = sanitizeTagValue(middleware)
        }
        
        // Record duration
        if config.recordDurations,
           let duration = extractDuration(from: event) {
            await recorder.record(.timer(
                "middleware.duration",
                duration: duration,
                tags: tags
            ))
        }
        
        // Record count
        if config.recordCounts {
            await recorder.record(.counter(
                "middleware.executed",
                tags: tags
            ))
        }
    }
    
    private func handleMiddlewareFailed(_ event: PipelineEvent, tags: [String: String]) async {
        var tags = tags
        
        // Add middleware and error info
        if let middleware = event.properties["middleware"]?.get(String.self) {
            tags["middleware"] = sanitizeTagValue(middleware)
        }
        
        if let errorType = event.properties["errorType"]?.get(String.self) {
            tags["error_type"] = sanitizeTagValue(errorType)
        }
        
        // Record error
        if config.recordErrors {
            await recorder.record(.counter(
                "middleware.error",
                tags: tags
            ))
        }
    }
    
    private func handleGenericCompleted(_ event: PipelineEvent, tags: [String: String]) async {
        let metricName = sanitizeMetricName(event.name)
        
        // Record duration if available
        if config.recordDurations,
           let duration = extractDuration(from: event) {
            await recorder.record(.timer(
                "\(metricName).duration",
                duration: duration,
                tags: tags
            ))
        }
        
        // Record count
        if config.recordCounts {
            await recorder.record(.counter(
                metricName,
                tags: tags
            ))
        }
    }
    
    private func handleGenericError(_ event: PipelineEvent, tags: [String: String]) async {
        let metricName = sanitizeMetricName(event.name)
        
        // Record error
        if config.recordErrors {
            await recorder.record(.counter(
                metricName,
                tags: tags
            ))
        }
    }
    
    private func extractDuration(from event: PipelineEvent) -> TimeInterval? {
        // Try different property names
        if let duration = event.properties["duration"]?.get(TimeInterval.self) {
            return duration
        }
        
        if let duration = event.properties["elapsed"]?.get(TimeInterval.self) {
            return duration
        }
        
        if let durationMs = event.properties["duration_ms"]?.get(Double.self) {
            return durationMs / 1000.0
        }
        
        return nil
    }
    
    private func extractTags(from event: PipelineEvent) -> [String: String] {
        var tags: [String: String] = [:]
        
        // Add standard tags
        if let userID = event.properties["userID"]?.get(String.self) {
            tags["user_id"] = sanitizeTagValue(userID)
        }
        
        // Add custom tags from properties if they look like tags
        for (key, value) in event.properties {
            if key.hasSuffix("_tag") || key.hasSuffix("Tag") {
                if let stringValue = value.get(String.self) {
                    let tagKey = key.replacingOccurrences(of: "_tag", with: "")
                        .replacingOccurrences(of: "Tag", with: "")
                    tags[sanitizeTagKey(tagKey)] = sanitizeTagValue(stringValue)
                }
            }
        }
        
        return tags
    }
    
    private func sanitizeMetricName(_ name: String) -> String {
        // Convert event names to metric-friendly format
        // e.g., "command.started" -> "command.started"
        // e.g., "middleware.timeout" -> "middleware.timeout"
        return name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
    
    private func sanitizeTagKey(_ key: String) -> String {
        return key
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .lowercased()
    }
    
    private func sanitizeTagValue(_ value: String) -> String {
        // StatsD has limitations on tag values
        return String(value.prefix(100))
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "@", with: "_")
    }
}

// MARK: - EventHub Extension for Natural Integration

public extension EventHub {
    /// Subscribes a metric recorder with automatic event-to-metric conversion.
    ///
    /// This provides natural integration between events and metrics.
    ///
    /// - Parameters:
    ///   - recorder: The metric recorder to use
    ///   - config: Configuration for metric generation
    func connectMetrics(
        _ recorder: any MetricRecorder,
        config: MetricsGenerationConfig = .default
    ) {
        let bridge = MetricsEventBridge(recorder: recorder, config: config)
        subscribe(bridge)
    }
}

// MARK: - Convenience Factory

public extension MetricsEventBridge {
    /// Creates a bridge that sends metrics to a MetricsStorage instance.
    static func toStorage(
        _ storage: MetricsStorage = MetricsStorage(),
        config: MetricsGenerationConfig = .default
    ) -> MetricsEventBridge {
        MetricsEventBridge(recorder: storage, config: config)
    }
    
    /// Creates a bridge that sends metrics to a StatsD exporter.
    static func toStatsD(
        configuration: StatsDExporter.Configuration = .default,
        metricsConfig: MetricsGenerationConfig = .default
    ) -> MetricsEventBridge {
        let exporter = StatsDExporter(configuration: configuration)
        return MetricsEventBridge(recorder: exporter, config: metricsConfig)
    }
}
