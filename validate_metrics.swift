import Foundation
import PipelineKitMetrics

print("Testing PipelineKitMetrics compilation and basic functionality...")

// Test basic types compile
let _ = StatsDExporter.Configuration.default
let _ = MetricSnapshot.counter("test", value: 1.0)
let _ = MetricsStorage()

print("✅ All types compile successfully")

// Test async functionality
Task {
    let storage = MetricsStorage()
    let exporter = StatsDExporter()
    
    await storage.record(MetricSnapshot.counter("test", value: 1.0))
    await exporter.record(MetricSnapshot.gauge("test", value: 2.0))
    await Metrics.counter("global", value: 3.0)
    
    print("✅ Async operations work")
    print("\n🎉 PipelineKitMetrics is functional!")
    exit(0)
}

RunLoop.main.run()