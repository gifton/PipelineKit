import Foundation
import PipelineKitObservability

/// Measures emitted lines and captured datagrams without contacting a server.
@main
struct MetricsAggregationExample {
    static func main() async throws {
        for aggregate in [false, true] {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                maxBatchSize: 20,
                flushInterval: 60,
                aggregation: .init(enabled: aggregate, flushInterval: 60, flushJitter: 0)
            ), transport: transport)
            for _ in 0..<100 {
                await exporter.counter("api.requests", tags: ["route": "/users"])
            }
            await exporter.gauge("queue.depth", value: 9)
            await exporter.gauge("queue.depth", value: 4)
            // Timer API input is seconds; these produce 100 ms and 150 ms.
            await exporter.timer("db.query", duration: 0.100)
            await exporter.timer("db.query", duration: 0.150)
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            let lines = packets.flatMap { $0.split(separator: "\n") }
            print("Aggregation enabled: \(aggregate)")
            print("Captured datagrams: \(packets.count); metric lines: \(lines.count)")
            if aggregate { print(lines.joined(separator: "\n")) }
            await exporter.close()
        }
        print("Batching combines lines into datagrams; aggregation also combines counter updates and keeps the latest gauge.")
        print("Timer/histogram observations remain separate. Packet counts here describe this mock-transport run.")
    }
}
