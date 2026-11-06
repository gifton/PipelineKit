import Foundation
import PipelineKit
import PipelineKitCore
import PipelineKitResilience
import PipelineKitObservability

private struct Input: Command {
    typealias Result = Int
    let value: Int
}

private struct Handler: CommandHandler {
    func handle(_ command: Input, context: CommandContext) async throws -> Int { command.value }
}

private struct Measurement: Encodable {
    let id: String
    let unit = "ns/batch"
    var samples: [UInt64] = []
    var operations: [Int] = []
    var results: [Int] = []
    let expected_result: Int
}

private enum BenchmarkError: Error {
    case invalidArguments
    case incorrectResult(String, Int, Int)
}

@main
private enum Benchmark {
    static func main() async throws {
        let arguments = CommandLine.arguments.dropFirst().compactMap(Int.init)
        guard arguments.count == 3, arguments.allSatisfy({ $0 > 0 }), arguments[0] <= 1_000_000 else {
            throw BenchmarkError.invalidArguments
        }
        let count: Int = arguments[0]
        let sampleCount: Int = arguments[1]
        let warmupCount: Int = arguments[2]
        var measurements: [Measurement] = []
        for name in ["dispatch", "context", "admission", "telemetry"] {
            let expected: Int = (name == "dispatch" || name == "context") ? count * (count + 1) / 2 : count
            var measurement = Measurement(id: name, expected_result: expected)
            for iteration in 0..<(warmupCount + sampleCount) {
                // Setup is outside the timed batch. Every batch starts with fresh state.
                let pipeline = StandardPipeline(handler: Handler())
                let context = CommandContext()
                let limiter = RateLimiter(strategy: .tokenBucket(capacity: Double(count), refillRate: 0), scope: .global)
                let storage = MetricsStorage(maxSnapshotsPerMetric: count, maxSeries: 1)
                let snapshot = MetricSnapshot(name: "benchmark.counter", type: "counter", value: 1, timestamp: 0)
                var result: Int = 0
                let start: UInt64 = DispatchTime.now().uptimeNanoseconds
                switch name {
                case "dispatch":
                    for value in 1...count {
                        result += try await pipeline.execute(Input(value: value), context: context)
                    }
                case "context":
                    for value in 1...count {
                        context.setMetadata("benchmark", value: value)
                        guard let observed = context.getMetadata("benchmark") as? Int else {
                            throw BenchmarkError.incorrectResult(name, -1, expected)
                        }
                        result += observed
                    }
                case "admission":
                    for _ in 0..<count {
                        if try await limiter.allowRequest(identifier: "benchmark") { result += 1 }
                    }
                default:
                    for _ in 0..<count { await storage.record(snapshot) }
                }
                let elapsed: UInt64 = DispatchTime.now().uptimeNanoseconds - start
                // All calls are awaited. Telemetry consumption is outside the timed batch.
                if name == "telemetry" {
                    let recorded = await storage.getAll()
                    guard recorded.count == count else {
                        throw BenchmarkError.incorrectResult(name, recorded.count, count)
                    }
                    result = Int(recorded.reduce(0.0) { $0 + ($1.value ?? 0) })
                }
                guard result == expected else { throw BenchmarkError.incorrectResult(name, result, expected) }
                if iteration >= warmupCount {
                    measurement.samples.append(elapsed)
                    measurement.operations.append(count)
                    measurement.results.append(result)
                }
            }
            measurements.append(measurement)
        }
        let data = try JSONEncoder().encode(measurements)
        print(String(decoding: data, as: UTF8.self))
    }
}
