import Foundation
import PipelineKitObservability

/// Checks captured output for this set of deterministically sampled names.
@main
enum MetricsSamplingExample {
    static func main() async throws {
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
                let fields = line.split(separator: "|")
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
        print("PASS: MetricsSamplingExample")
    }
}

enum ExampleFailure: Error {
    case unsubmittedName, noSamplingObserved, partialName, invalidSampleAnnotation, criticalNameNotRetained
}
