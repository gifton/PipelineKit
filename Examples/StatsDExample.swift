#!/usr/bin/env swift

import Foundation
import PipelineKitObservability

// Example: Using the StatsD Exporter

@main
struct StatsDExample {
    static func main() async throws {
        print("StatsD Exporter Example")
        print(String(repeating: "=", count: 50))
        
        // MARK: - Configuration Examples
        
        print("\nConfiguration Examples:")
        print("-" * 20)
        
        // Example 1: Default configuration (DogStatsD format)
        let defaultConfig = StatsDExporter.Configuration.default
        print("Default: \(defaultConfig.host):\(defaultConfig.port)")
        
        // Example 2: Vanilla StatsD (no tags)
        let vanillaConfig = StatsDExporter.Configuration(
            host: "localhost",
            port: 8125,
            format: .vanilla
        )
        print("Vanilla StatsD: No tags support")
        
        // Example 3: DogStatsD with global tags
        let dogstatsdConfig = StatsDExporter.Configuration(
            host: "dd-agent.monitoring.svc.cluster.local",
            port: 8125,
            prefix: "myapp",
            globalTags: [
                "environment": "production",
                "service": "api-gateway",
                "version": "2.1.0",
                "region": "us-west-2"
            ],
            sampleRate: 1.0,
            format: .dogStatsD
        )
        print("DogStatsD: With tags and prefix")
        
        // Example 4: Low sample rate for high-volume metrics
        let sampledConfig = StatsDExporter.Configuration(
            sampleRate: 0.1,  // Only send 10% of metrics
            maxPacketSize: 512,  // Smaller packets
            flushInterval: 0.5   // Flush more frequently
        )
        print("Sampled: 10% sample rate for high volume")
        
        // MARK: - Basic Usage
        
        print("\nBasic Usage:")
        print("-" * 20)
        
        let exporter = StatsDExporter(configuration: dogstatsdConfig)
        
        // Counter metric
        let counterMetric = MetricSnapshot(
            name: "api.requests.count",
            type: "counter",
            value: 1,
            timestamp: Date(),
            tags: [
                "method": "GET",
                "endpoint": "/api/users",
                "status": "200"
            ],
            unit: nil
        )
        
        // Gauge metric
        let gaugeMetric = MetricSnapshot(
            name: "memory.heap.used",
            type: "gauge",
            value: 67.5,
            timestamp: Date(),
            tags: [
                "process": "api-server"
            ],
            unit: "percent"
        )
        
        // Histogram metric
        let histogramMetric = MetricSnapshot(
            name: "db.query.duration",
            type: "histogram",
            value: 45.2,
            timestamp: Date(),
            tags: [
                "database": "users",
                "operation": "select"
            ],
            unit: "milliseconds"
        )
        
        // Timer metric (in seconds, will be converted to ms)
        let timerMetric = MetricSnapshot(
            name: "http.request.duration",
            type: "timer",
            value: 0.125,  // 125ms
            timestamp: Date(),
            tags: [
                "method": "POST",
                "endpoint": "/api/orders"
            ],
            unit: "seconds"
        )
        
        // Export metrics
        try await exporter.export([
            counterMetric,
            gaugeMetric,
            histogramMetric,
            timerMetric
        ])
        
        print("Exported 4 metrics")
        
        // MARK: - Batching Example
        
        print("\nBatching Example:")
        print("-" * 20)
        
        // Create batching wrapper for efficient packet usage
        let batchedExporter = await BatchingExporter(
            underlying: exporter,
            maxBatchSize: 50,      // Batch up to 50 metrics
            maxBufferSize: 1000,    // Buffer up to 1000 metrics
            bufferPolicy: .dropOldest,
            maxBatchAge: 1.0,       // Flush every second
            autostart: true
        )
        
        // Send many metrics efficiently
        for i in 1...100 {
            let metric = MetricSnapshot(
                name: "batch.counter",
                type: "counter",
                value: Double(i),
                timestamp: Date(),
                tags: ["batch": "test", "index": "\(i)"],
                unit: nil
            )
            
            try await batchedExporter.export([metric])
            
            if i % 25 == 0 {
                print("  Sent \(i) metrics...")
            }
        }
        
        // Force flush remaining metrics
        try await batchedExporter.flush()
        print("  Flushed remaining metrics")
        
        // MARK: - Multi-Exporter Example
        
        print("\nMulti-Exporter Example:")
        print("-" * 20)
        
        // Send to multiple destinations
        let multiExporter = MultiExporter(exporters: [
            StatsDExporter(configuration: vanillaConfig),  // Vanilla StatsD
            StatsDExporter(configuration: dogstatsdConfig), // DogStatsD
            ConsoleExporter(format: .compact, prefix: "[LOCAL]")
        ])
        
        let multiMetric = MetricSnapshot(
            name: "multi.test",
            type: "gauge",
            value: 42.0,
            timestamp: Date(),
            tags: ["destination": "multiple"],
            unit: nil
        )
        
        try await multiExporter.export([multiMetric])
        print("Sent to multiple exporters")
        
        // MARK: - Statistics
        
        print("\nExporter Statistics:")
        print("-" * 20)
        
        let stats = await exporter.getStats()
        print("  Packets sent: \(stats.packetsTotal)")
        print("  Metrics sent: \(stats.metricsTotal)")
        print("  Metrics dropped: \(stats.droppedMetricsTotal)")
        print("  Network errors: \(stats.networkErrorsTotal)")
        print("  Current buffer: \(stats.currentBufferSize) bytes")
        
        // MARK: - Shutdown
        
        await batchedExporter.shutdown()
        await exporter.shutdown()
        
        print("\nExample complete!")
        print("")
        print("Note: Metrics were sent via UDP to \(dogstatsdConfig.host):\(dogstatsdConfig.port)")
        print("      If no StatsD server is running, packets were silently dropped (expected for UDP)")
        print("")
        print("To test with a real StatsD server:")
        print("  1. Install StatsD: npm install -g statsd")
        print("  2. Run: statsd config.js")
        print("  3. Or use Docker: docker run -p 8125:8125/udp statsd/statsd")
        print("")
        print("For DogStatsD (DataDog):")
        print("  1. Install DD agent: https://docs.datadoghq.com/agent/")
        print("  2. Configure dogstatsd_port: 8125")
        print("  3. Enable dogstatsd_non_local_traffic if needed")
    }
}

// Helper extension
extension String {
    static func *(lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}