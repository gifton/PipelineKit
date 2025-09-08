//
//  PipelineKitObservability.swift
//  PipelineKit
//
//  Unified observability module combining events and metrics
//

import Foundation

/// PipelineKit Observability Module
///
/// This module provides comprehensive observability capabilities including:
/// - Event-driven observability with EventHub and EventEmitter
/// - Type-safe metrics collection and aggregation
/// - Multiple export formats (StatsD, Logging, etc.)
/// - Automatic event-to-metric conversion capabilities
///
/// ## Architecture
///
/// The module is organized into distinct subsystems:
/// - **Events**: High-level event routing and distribution
/// - **Metrics**: Low-level metric collection and aggregation
/// - **Exporters**: Output adapters for various monitoring systems
/// - **Aggregation**: Statistical processing and sampling
///
/// ## Usage Example
/// ```swift
/// // Setup event hub
/// let eventHub = EventHub()
/// let logger = LoggingEmitter()
/// await eventHub.subscribe(logger)
///
/// // Setup metrics
/// let metrics = MetricsStorage()
/// let exporter = StatsDExporter(configuration: .default)
/// 
/// // Emit events
/// context.eventEmitter = eventHub
/// context.emitCommandStarted(type: "CreateUser")
///
/// // Record metrics
/// await metrics.record(.counter("api.requests", tags: ["endpoint": "users"]))
/// ```
public enum PipelineKitObservability {
    /// Current version of the observability module
    public static let version = "0.1.0"
    
    /// Module capabilities
    public enum Capabilities {
        public static let supportsEvents = true
        public static let supportsMetrics = true
        public static let supportsTracing = false // Future
        public static let supportsAPM = false // Future
    }
}
