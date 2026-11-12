import Foundation
import PipelineKitObservability

/// Two checks of `StatsDExporter` against captured output: deterministic
/// whole-name sampling, then the same metrics with aggregation off and on.
/// Neither depends on packet order, a collector or the network.
@main
enum StatsDExportExample {
    static func main() async throws {
        try await checkSampling()
        try await checkAggregation()
        print("PASS: StatsDExportExample")
    }

    /// Checks captured output for this set of deterministically sampled names.
    static func checkSampling() async throws {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: .init(
            maxBatchSize: 1000,
            flushInterval: 60,
            sampleRate: 0.25,
            criticalPatterns: ["error"]
        ), transport: transport)
        let submittedNames = Set((0..<100).map { "requests.endpoint.\($0)" })
        for name in submittedNames.sorted() {
            for _ in 0..<3 { await exporter.counter(name) }
        }
        await exporter.counter("requests.error")
        await exporter.forceFlush()
        // close clears the mock capture, so retain the delivered output first.
        let packets = await transport.getMetricsAsStrings()
        await exporter.close()
        let lines = packets.flatMap { $0.split(separator: "\n").map(String.init) }
        let grouped = Dictionary(grouping: lines) { $0.split(separator: ":", maxSplits: 1)[0] }
        guard Set(grouped.keys.map(String.init)).isSubset(of: submittedNames.union(["requests.error"])) else {
            throw ExampleFailure.unsubmittedName
        }
        let retainedNames = submittedNames.filter { grouped[Substring($0)] != nil }
        guard !retainedNames.isEmpty, retainedNames.count < submittedNames.count else {
            throw ExampleFailure.noSamplingObserved
        }
        for name in submittedNames {
            let emitted = grouped[Substring(name)] ?? []
            guard emitted.isEmpty || emitted.count == 3 else { throw ExampleFailure.partialName }
            for line in emitted {
                let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                guard fields.count == 3, fields[0] == "\(name):1.0",
                      fields[1] == "c", fields[2] == "@0.25" else {
                    throw ExampleFailure.invalidSampleAnnotation
                }
            }
        }
        guard grouped["requests.error"] == ["requests.error:1.0|c"] else {
            throw ExampleFailure.criticalNameNotRetained
        }
        print("100 ordinary names, 3 updates per name; selected names: \(retainedNames.count)")
        print("Captured critical counter bypassed sampling; retained ordinary increments carry @0.25.")
        print("Whole-name selection does not establish per-event randomness or an accurate estimate for one name.")
    }

    /// Checks metric fields in captured output without depending on packet order.
    static func checkAggregation() async throws {
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
            // Timer API input is seconds; wire values are milliseconds.
            await exporter.timer("db.query", duration: 0.100)
            await exporter.timer("db.query", duration: 0.150)
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            await exporter.close()
            let records = try packets.flatMap { $0.split(separator: "\n") }.map(WireMetric.init)
            guard Set(records.map(\.name)) == ["api.requests", "queue.depth", "db.query"] else {
                throw ExampleFailure.unexpectedNames
            }
            let counters = records.filter { $0.name == "api.requests" }
            guard counters.count == (aggregate ? 1 : 100),
                  counters.allSatisfy({ $0.type == "c" && $0.options == ["#route:/users"] }),
                  abs(counters.reduce(0) { $0 + $1.value } - 100) < 0.000_001 else {
                throw ExampleFailure.incorrectCounterTotal
            }
            let gauges = records.filter { $0.name == "queue.depth" }
            let gaugeValues = gauges.map(\.value).sorted()
            let expectedGauges: [Double] = aggregate ? [4] : [4, 9]
            guard gauges.allSatisfy({ $0.type == "g" && $0.options.isEmpty }),
                  gaugeValues.count == expectedGauges.count,
                  zip(gaugeValues, expectedGauges).allSatisfy({ abs($0 - $1) < 0.000_001 }) else {
                throw ExampleFailure.incorrectGauge
            }
            let timers = records.filter { $0.name == "db.query" }
            guard timers.count == 2, timers.allSatisfy({ $0.type == "ms" && $0.options.isEmpty }),
                  zip(timers.map(\.value).sorted(), [100.0, 150.0]).allSatisfy({ abs($0 - $1) < 0.000_001 }) else {
                throw ExampleFailure.incorrectTimers
            }
            print("Aggregation enabled: \(aggregate); verified counter total 100, gauge values, and both timers.")
        }
        print("Captured output verified with aggregation disabled and enabled; exporters closed.")
    }
}

private struct WireMetric {
    let name: String
    let value: Double
    let type: String
    let options: Set<String>

    init(_ line: Substring) throws {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        let pair = fields[0].split(separator: ":", maxSplits: 1)
        guard fields.count >= 2, pair.count == 2, let value = Double(pair[1]), value.isFinite else {
            throw ExampleFailure.malformedWireMetric
        }
        self.name = String(pair[0])
        self.value = value
        self.type = String(fields[1])
        self.options = Set(fields.dropFirst(2).map(String.init))
    }
}

enum ExampleFailure: Error {
    case unsubmittedName, noSamplingObserved, partialName, invalidSampleAnnotation, criticalNameNotRetained
    case malformedWireMetric, unexpectedNames, incorrectCounterTotal, incorrectGauge, incorrectTimers
}
