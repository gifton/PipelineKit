// PipelineKitMetrics - Type-safe metrics with efficient accumulation.
//
// This module provides a modern, type-safe metrics API with:
// - Phantom types for compile-time safety
// - Semantic types to prevent parameter confusion
// - Memory-efficient statistical accumulators
// - Time-based aggregation windows
// - Prometheus export support
//
// ## Usage
// ```swift
// import PipelineKitMetrics
//
// // Type-safe metric creation
// let counter = Metric<Counter>.counter("api.requests")
// let histogram = Metric<Histogram>.histogram("api.latency", value: 125.5, unit: .milliseconds)
// let gauge = Metric<Gauge>.gauge("memory.usage", value: 0.75, unit: .percentage)
//
// // Window-based aggregation
// let window = AggregationWindow.sliding(duration: 60, buckets: 6)
// let accumulator = window.createAccumulator(
//     type: HistogramAccumulator.self,
//     config: .default
// )
//
// // Export to Prometheus
// let exporter = PrometheusExporter()
// let prometheusText = exporter.export([counter.snapshot()])
// ```
//
// This file serves as the module documentation.
// All types are automatically available when importing PipelineKitMetrics.
