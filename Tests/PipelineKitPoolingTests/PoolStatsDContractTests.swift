import XCTest
@testable import PipelineKitPooling

@MainActor
final class PoolStatsDContractTests: XCTestCase {
    func testRepeatedNegativeGaugeSnapshotsRemainAbsolute() async {
        let metrics = PoolObservability()
        await metrics.setGauge("depth", value: -3)
        var received: Double = 0
        for _ in 0..<2 {
            let datagrams = await metrics.captureSnapshot().statsdFormat()
            XCTAssertEqual(datagrams.count, 1)
            XCTAssertEqual(datagrams.first?.split(separator: "\n").count, 2,
                           "Reset and signed update must share one datagram")
            for datagram in datagrams {
                for line in datagram.split(separator: "\n") {
                    let fields = line.split(separator: ":", maxSplits: 1)
                    guard fields.count == 2,
                          let raw = fields[1].split(separator: "|").first,
                          let value = Double(raw) else {
                        XCTFail("Malformed gauge packet")
                        continue
                    }
                    if raw.hasPrefix("-") || raw.hasPrefix("+") { received += value }
                    else { received = value }
                }
            }
            XCTAssertEqual(received, -3, accuracy: 0.001)
        }
    }

    func testStructuredLabelsUseDogStatsDTagsAndPreserveCounterInteger() async {
        let metrics = PoolObservability()
        await metrics.incrementCounter("requests", by: .max, labels: ["region": "west", "pool": "a:b"])
        let result = await metrics.captureSnapshot().statsdFormatWithDiagnostics()
        let datagrams = result.datagrams
        XCTAssertEqual(datagrams, ["requests:18446744073709551615|g|#pool:a:b,region:west"])
        XCTAssertEqual(result.rejectedSeriesCount, 0)
    }

    func testInvalidNamesAndProtocolLabelsAreOmitted() async {
        let metrics = PoolObservability()
        await metrics.setGauge("keep", value: 9)
        for name in ["", "bad:name", "bad|name", "bad\nname", "bad\rname", "bad@name", "bad#name", "bad name"] {
            await metrics.setGauge(name, value: 1)
        }
        for labels in [["": "x"], ["bad:key": "x"], ["bad,key": "x"],
                       ["key": "x|g"], ["key": "x\nother:9|c"], ["key": "x,y"]] {
            await metrics.setGauge("labels", value: 1, labels: labels)
        }
        let result = await metrics.captureSnapshot().statsdFormatWithDiagnostics()
        let datagrams = result.datagrams
        XCTAssertEqual(datagrams.count, 1)
        XCTAssertTrue(datagrams.first?.hasPrefix("keep:9") == true)
        XCTAssertEqual(result.rejectedSeriesCount, 14)
    }

    func testDistributionStatisticsAreGaugesAndSummariesAreIncluded() async {
        let metrics = PoolObservability(distributionWindowSize: 1)
        await metrics.recordHistogram("latency", value: 2)
        await metrics.recordHistogram("latency", value: 4)
        await metrics.recordSummary("size", value: 5)
        let datagrams = await metrics.captureSnapshot().statsdFormat()
        var values: [String: Double] = [:]
        for datagram in datagrams {
            let fields = datagram.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { XCTFail("Missing name/value separator"); continue }
            let sample = fields[1].split(separator: "|")
            XCTAssertEqual(sample.dropFirst().first, "g")
            values[String(fields[0])] = sample.first.flatMap { Double($0) }
        }
        let expected: [String: Double] = [
            "latency_count": 2, "latency_sum": 6, "latency_mean": 3,
            "latency_min": 2, "latency_max": 4, "latency_p50": 4,
            "latency_p95": 4, "latency_p99": 4,
            "size_count": 1, "size_sum": 5, "size_p50": 5, "size_p90": 5,
            "size_p95": 5, "size_p99": 5, "size_p999": 5
        ]
        XCTAssertEqual(Set(values.keys), Set(expected.keys))
        for (name, value) in expected { XCTAssertEqual(values[name] ?? -1, value, accuracy: 0.001, name) }
    }

    func testMetricKindAndGeneratedNameCollisionsRejectEveryAffectedSeries() async {
        for reversed in [false, true] {
            let metrics = PoolObservability()
            await metrics.setGauge("keep", value: 9)
            if reversed {
                await metrics.setGauge("shared", value: 3)
                await metrics.incrementCounter("shared", by: 2)
                await metrics.setGauge("latency_mean", value: 1)
                await metrics.recordHistogram("latency", value: 2)
            } else {
                await metrics.incrementCounter("shared", by: 2)
                await metrics.setGauge("shared", value: 3)
                await metrics.recordHistogram("latency", value: 2)
                await metrics.setGauge("latency_mean", value: 1)
            }
            let result = await metrics.captureSnapshot().statsdFormatWithDiagnostics()
            let datagrams = result.datagrams
            XCTAssertEqual(datagrams.count, 1)
            XCTAssertTrue(datagrams.first?.hasPrefix("keep:9") == true)
            XCTAssertEqual(result.rejectedSeriesCount, 4)
        }
    }

    func testDogStatsDEmptyTagValuesRemainDistinctFromAbsentTags() async {
        let metrics = PoolObservability()
        await metrics.incrementCounter("count")
        await metrics.incrementCounter("count", labels: ["optional": ""])
        let result = await metrics.captureSnapshot().statsdFormatWithDiagnostics()
        XCTAssertEqual(result.rejectedSeriesCount, 0)
        XCTAssertEqual(result.datagrams, ["count:1|g", "count:1|g|#optional:"])
    }
}
