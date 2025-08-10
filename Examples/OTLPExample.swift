#!/usr/bin/env swift

import Foundation
import PipelineKitMetrics

// Example: Using the OTLP Exporter

@main
struct OTLPExample {
    static func main() async throws {
        print("🚀 OTLP Exporter Example")
        print("=" * 50)
        
        // Configure OTLP exporter
        let config = OTLPExporter.Configuration(
            endpoint: URL(string: "http://localhost:4318/v1/metrics")!,
            headers: [
                "X-API-Key": "your-api-key-here"
            ],
            resourceAttributes: [
                "environment": "development",
                "service.version": "1.0.0",
                "host.name": ProcessInfo.processInfo.hostName
            ],
            serviceName: "example-service",
            compression: true,
            maxRetries: 3,
            retryDelay: 1.0
        )
        
        print("📊 Configuration:")
        print("  Endpoint: \(config.endpoint)")
        print("  Service: \(config.serviceName)")
        print("  Compression: \(config.compression)")
        print("  Max Retries: \(config.maxRetries)")
        print("")
        
        // Create the exporter
        let otlpExporter = OTLPExporter(configuration: config)
        
        // Option 1: Direct export
        print("📤 Direct Export Example:")
        let metrics = [
            MetricSnapshot(
                name: "http.requests.total",
                type: "counter",
                value: 1234,
                timestamp: Date(),
                tags: [
                    "method": "GET",
                    "endpoint": "/api/users",
                    "status": "200"
                ],
                unit: "count"
            ),
            MetricSnapshot(
                name: "http.request.duration",
                type: "histogram",
                value: 125.5,
                timestamp: Date(),
                tags: [
                    "method": "GET",
                    "endpoint": "/api/users"
                ],
                unit: "milliseconds"
            ),
            MetricSnapshot(
                name: "memory.usage",
                type: "gauge",
                value: 67.8,
                timestamp: Date(),
                tags: [
                    "process": "api-server"
                ],
                unit: "percent"
            )
        ]
        
        do {
            try await otlpExporter.export(metrics)
            print("✅ Metrics exported successfully!")
        } catch {
            print("❌ Export failed: \(error)")
            print("   (This is expected if no OTLP collector is running)")
        }
        
        print("")
        
        // Option 2: With batching
        print("📦 Batched Export Example:")
        let batchingExporter = await BatchingExporter(
            underlying: otlpExporter,
            maxBatchSize: 100,
            maxBufferSize: 10_000,
            bufferPolicy: .dropOldest,
            maxBatchAge: 5.0,
            autostart: true
        )
        
        // Send metrics in small batches
        for i in 1...10 {
            let metric = MetricSnapshot(
                name: "batch.test.counter",
                type: "counter",
                value: Double(i),
                timestamp: Date(),
                tags: ["batch": "test", "index": "\(i)"],
                unit: "count"
            )
            
            do {
                try await batchingExporter.export([metric])
                print("  Added metric \(i) to batch")
            } catch {
                print("  Failed to add metric \(i): \(error)")
            }
        }
        
        // Force flush
        print("  Flushing batch...")
        do {
            try await batchingExporter.flush()
            print("✅ Batch flushed successfully!")
        } catch {
            print("❌ Batch flush failed: \(error)")
            print("   (This is expected if no OTLP collector is running)")
        }
        
        // Get stats
        let stats = await batchingExporter.getStats()
        print("")
        print("📈 Exporter Statistics:")
        print("  Exports: \(stats.exportsTotal)")
        print("  Failures: \(stats.exportFailuresTotal)")
        print("  Metrics Exported: \(stats.metricsExportedTotal)")
        print("  Metrics Dropped: \(stats.metricsDroppedTotal)")
        
        // Option 3: Multi-exporter setup
        print("")
        print("🔀 Multi-Exporter Example:")
        let multiExporter = MultiExporter(exporters: [
            ConsoleExporter(format: .compact, prefix: "[LOCAL]"),
            otlpExporter,
            NullExporter()
        ])
        
        let multiMetric = MetricSnapshot(
            name: "multi.exporter.test",
            type: "gauge",
            value: 42.0,
            timestamp: Date(),
            tags: ["exporter": "multi"],
            unit: nil
        )
        
        do {
            try await multiExporter.export([multiMetric])
            print("✅ Multi-export successful!")
        } catch {
            print("❌ Multi-export failed: \(error)")
            print("   (Console should have succeeded even if OTLP failed)")
        }
        
        // Shutdown
        await batchingExporter.shutdown()
        await otlpExporter.shutdown()
        
        print("")
        print("✨ Example complete!")
        print("")
        print("💡 To test with a real OTLP collector:")
        print("   1. Run: docker run -p 4318:4318 otel/opentelemetry-collector")
        print("   2. Run this example again")
    }
}

// Helper to repeat strings
extension String {
    static func *(lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}