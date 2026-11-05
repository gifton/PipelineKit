import Foundation
import PipelineKitObservability

/// Demonstrates deterministic name selection using actual exporter output.
@main
struct MetricsSamplingExample {
    static func main() async throws {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: .init(
            maxBatchSize: 1000, flushInterval: 60, sampleRate: 0.25,
            criticalPatterns: ["error"]
        ), transport: transport)
        for index in 0..<100 {
            // Every update of one name receives the same selection decision.
            let name = "requests.endpoint.\(index)"
            for _ in 0..<3 { await exporter.counter(name) }
        }
        await exporter.counter("requests.error")
        await exporter.forceFlush()
        let packets = await transport.getMetricsAsStrings()
        let lines = packets.flatMap { $0.split(separator: "\n") }
        let ordinary = lines.filter { !$0.hasPrefix("requests.error:") }
        let retainedNames = Set(ordinary.map { $0.split(separator: ":", maxSplits: 1)[0] })
        print("100 ordinary names, 3 updates per name; selected names: \(retainedNames.count)")
        print("Ordinary emitted lines: \(ordinary.count); captured datagrams: \(packets.count)")
        print("Retained counter increments carry @0.25; the receiver applies compensation once.")
        print("The critical error name bypasses sampling:")
        for line in lines where line.hasPrefix("requests.error:") { print(line) }
        print("This selects whole names, not independent events. It does not guarantee an accurate estimate for any one name.")
        await exporter.close()
    }
}
