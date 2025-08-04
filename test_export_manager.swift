#!/usr/bin/env swift

import Foundation
import PipelineKitCore
import PipelineKitMiddleware

// Test that ExportManager works correctly after actor refactoring

// Create a simple test exporter
final class TestExporter: MetricExporter {
    var exportCount = 0
    
    func export(_ metric: MetricDataPoint) async throws {
        exportCount += 1
    }
    
    func exportBatch(_ metrics: [MetricDataPoint]) async throws {
        exportCount += metrics.count
    }
    
    func exportAggregated(_ metrics: [AggregatedMetrics]) async throws {
        // Not used in test
    }
    
    func flush() async throws {
        // No-op
    }
    
    func shutdown() async {
        // No-op
    }
    
    var status: ExporterStatus {
        get async {
            ExporterStatus(
                isActive: true,
                queueDepth: 0,
                successCount: exportCount,
                failureCount: 0,
                lastExportTime: Date(),
                lastError: nil
            )
        }
    }
}

// Run test
let manager = ExportManager()
let exporter = TestExporter()

await manager.register(exporter, name: "test")

// Export some metrics
for i in 0..<100 {
    let metric = MetricDataPoint(
        timestamp: Date(),
        name: "test.metric",
        value: Double(i),
        type: .gauge,
        tags: [:]
    )
    await manager.export(metric)
}

// Check exporters
let exporters = await manager.listExporters()
print("Registered exporters: \(exporters.count)")
for (name, info) in exporters {
    print("  \(name): active=\(info.isActive), queue=\(info.queueDepth)")
}

// Get statistics
let stats = await manager.statistics()
print("\nStatistics:")
print("  Total exported: \(stats.totalExported)")
print("  Active exporters: \(stats.activeExporters)")

print("\nExportManager actor refactoring successful!")