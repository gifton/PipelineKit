import Foundation
import XCTest
@testable import PipelineKitObservability

final class TelemetryNumericBoundaryTests: XCTestCase {
    /// The host driver runs each selected boundary in a separate process.
    func testNumericConfigurationProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let entry = environment["PIPELINEKIT_NUMERIC_ENTRY"],
              let raw = environment["PIPELINEKIT_NUMERIC_VALUE"], let value = Double(raw) else { return }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_REACHED\n".utf8))
        switch entry {
        case "telemetry-event-cleanup": _ = EventHub(cleanupInterval: value)
        case "telemetry-batch-interval": _ = StatsDExporter.Configuration(flushInterval: value)
        case "telemetry-aggregation-interval": _ = AggregationConfiguration(flushInterval: value)
        case "telemetry-sample-rate": _ = StatsDExporter.Configuration(sampleRate: value)
        case "telemetry-type-rate": _ = StatsDExporter.Configuration(sampleRatesByType: ["counter": value])
        case "telemetry-jitter": _ = AggregationConfiguration(flushJitter: value)
        case "telemetry-batch-capacity": _ = StatsDExporter.Configuration(maxBatchSize: Int(raw)!)
        case "telemetry-aggregation-series": _ = AggregationConfiguration(maxUniqueMetrics: Int(raw)!)
        case "telemetry-aggregation-values": _ = AggregationConfiguration(maxTotalValues: Int(raw)!)
        case "telemetry-storage-series": _ = MetricsStorage(maxSeries: Int(raw)!)
        case "telemetry-storage-history": _ = MetricsStorage(maxSnapshotsPerMetric: Int(raw)!)
        case "telemetry-trace-capacity": _ = ExecutionTracer.Configuration(maxTraces: Int(raw)!)
        case "telemetry-trace-retention": _ = ExecutionTracer.Configuration(retentionTime: value)
        case "telemetry-storage-age":
            let storage = MetricsStorage()
            await storage.record(.counter("age"))
            await storage.pruneOlderThan(value)
        default: XCTFail("Unknown telemetry numeric probe \(entry)")
        }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_ACCEPTED\n".utf8))
    }
}
