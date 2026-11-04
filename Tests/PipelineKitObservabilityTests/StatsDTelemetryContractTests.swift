import Foundation
import Synchronization
import XCTest
import PipelineKitCore
@testable import PipelineKitObservability

final class StatsDTelemetryContractTests: XCTestCase {
    func testMaximumAggregationDelayIsCappedAndScheduledWithoutOverflow() async {
        let configuration = AggregationConfiguration(enabled: true, flushInterval: NumericDuration.maximumSeconds,
                                                      flushJitter: 0)
        XCTAssertEqual(configuration.flushDelay(jitter: 0.2), NumericDuration.maximumSeconds, accuracy: 0.000_001)
        let sleeper = ControlledMetricSleeper()
        let transport = TelemetryPacketTransport(onSend: {})
        let exporter = StatsDExporter(configuration: .init(aggregation: configuration), transport: transport,
                                      sleep: { try await sleeper.sleep($0) })
        await exporter.counter("maximum.interval")
        await sleeper.waitForCount(1)
        let interval = await sleeper.intervals.first ?? -1
        XCTAssertEqual(interval, NumericDuration.maximumSeconds, accuracy: 0.000_001)
        let timer = await exporter.timerTasks.values.first
        await sleeper.release(1)
        await timer?.value
        let packets = await transport.packets
        XCTAssertEqual(packets, ["maximum.interval:1.0|c"])
        await exporter.close()
    }

    func testMissingValuesAreOnlyAcceptedForCounters() async throws {
        for aggregationEnabled in [false, true] {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                flushInterval: 60, aggregation: .init(enabled: aggregationEnabled, flushInterval: 60)
            ), transport: transport)
            let failures = Mutex(0)
            await exporter.setErrorHandler { error in
                if case MetricsError.invalidData = error { failures.withLock { $0 += 1 } }
            }
            for type in ["counter", "gauge", "timer", "histogram", "custom"] {
                await exporter.record(.init(name: type, type: type))
            }
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            XCTAssertEqual(packets, ["counter:1.0|c"])
            XCTAssertEqual(failures.withLock { $0 }, 4)
            await exporter.close()
        }
    }

    func testTimerRejectsExplicitNonMillisecondUnits() async throws {
        for aggregationEnabled in [false, true] {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                flushInterval: 60, aggregation: .init(enabled: aggregationEnabled, flushInterval: 60)
            ), transport: transport)
            let failures = Mutex(0)
            await exporter.setErrorHandler { error in
                if case MetricsError.invalidData = error { failures.withLock { $0 += 1 } }
            }
            await exporter.record(.init(name: "seconds", type: "timer", value: 1, unit: "seconds"))
            await exporter.record(.init(name: "legacy", type: "timer", value: 2))
            await exporter.record(.init(name: "milliseconds", type: "timer", value: 3, unit: "ms"))
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            XCTAssertEqual(packets.sorted(), ["legacy:2.0|ms", "milliseconds:3.0|ms"])
            XCTAssertEqual(failures.withLock { $0 }, 1)
            await exporter.close()
        }
    }

    func testAggregationRejectsConflictingWireDefinitionsWithinWindow() async throws {
        let cases: [(MetricSnapshot, MetricSnapshot, String)] = [
            (.gauge("space name", value: 1), .gauge("space_name", value: 2), "space_name:1.0|g"),
            (.gauge("units", value: 1, unit: "items"), .gauge("units", value: 2, unit: "bytes"), "units:1.0|g"),
            (.gauge("kind", value: 1), .init(name: "kind", type: "custom", value: 2), "kind:1.0|g")
        ]
        for (first, conflicting, expected) in cases {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                flushInterval: 60, aggregation: .init(enabled: true, flushInterval: 60)
            ), transport: transport)
            let failures = Mutex(0)
            await exporter.setErrorHandler { error in
                if case MetricsError.invalidData = error { failures.withLock { $0 += 1 } }
            }
            await exporter.record(first)
            await exporter.record(conflicting)
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            XCTAssertEqual(packets, [expected])
            XCTAssertEqual(failures.withLock { $0 }, 1)
            await exporter.close()
        }
    }

    func testDescendantAfterTimerSettlementMustJoinTransportClose() async {
        let premature = expectation(description: "stale task-local owner does not bypass close settlement")
        premature.isInverted = true
        let observing = Mutex(true)
        let transport = DescendantCloseTelemetryTransport {
            if observing.withLock({ $0 }) { premature.fulfill() }
        }
        let exporter = StatsDExporter(configuration: .init(maxBatchSize: 100, flushInterval: 0), transport: transport)
        await transport.install(exporter)
        await exporter.counter("descendant")
        await transport.waitForSend()
        let timers = await exporter.timerTasks.values.map { $0 }
        for timer in timers { await timer.value }
        await transport.releaseChild()
        await transport.waitForClose()
        await fulfillment(of: [premature], timeout: 0.2)
        observing.withLock { $0 = false }
        await transport.releaseClose()
        await transport.joinChild()
        await exporter.close()
        await transport.uninstall()
    }

    func testCallerOwnedSendsCanReenterCloseWhenTransportCloseWaitsForSend() async {
        for immediate in [false, true] {
            let returned = expectation(description: "caller-owned send returns from close")
            let transport = SendSettlingTelemetryTransport(returned: { returned.fulfill() })
            let exporter = StatsDExporter(configuration: .init(maxBatchSize: immediate ? 1 : 100, flushInterval: 60),
                                          transport: transport)
            await transport.install(exporter)
            let work = Task {
                await exporter.counter("caller.owned")
                if !immediate { await exporter.forceFlush() }
            }
            await fulfillment(of: [returned], timeout: 1)
            guard await transport.didReturn else { continue }
            await work.value
            await exporter.close()
            let closes = await transport.closeCount
            XCTAssertEqual(closes, 1)
            await transport.uninstall()
        }
    }

    func testStartupFactoryCanReenterClose() async {
        let reference = Mutex<StatsDExporter?>(nil)
        let transport = TelemetryPacketTransport(onSend: {})
        let exporter = StatsDExporter(configuration: .default, transportFactory: {
            let exporter = reference.withLock { $0 }
            await exporter?.close()
            return transport
        })
        reference.withLock { $0 = exporter }
        do {
            try await exporter.start()
            XCTFail("Factory closed exporter before publishing transport")
        } catch TransportError.transportClosed { } catch { XCTFail("Unexpected error: \(error)") }
        await exporter.close()
        reference.withLock { $0 = nil }
    }

    func testNestedStartupFactoryCanCloseOuterExporter() async {
        let outerReference = Mutex<StatsDExporter?>(nil)
        let innerTransport = TelemetryPacketTransport(onSend: {})
        let outerTransport = TelemetryPacketTransport(onSend: {})
        let inner = StatsDExporter(configuration: .default, transportFactory: {
            let outer = outerReference.withLock { $0 }
            await outer?.close()
            return innerTransport
        })
        let outer = StatsDExporter(configuration: .default, transportFactory: {
            try await inner.start()
            return outerTransport
        })
        outerReference.withLock { $0 = outer }
        do {
            try await outer.start()
            XCTFail("Nested factory closed the outer exporter")
        } catch TransportError.transportClosed { } catch { XCTFail("Unexpected error: \(error)") }
        await outer.close()
        await inner.close()
        outerReference.withLock { $0 = nil }
    }

    func testCapacityFlushAndFinalFlushEachDeliverTheirRetainedObservationsOnce() async throws {
        for configuration in [AggregationConfiguration(enabled: true, flushInterval: 60, maxUniqueMetrics: 1),
                              AggregationConfiguration(enabled: true, flushInterval: 60, maxTotalValues: 2)] {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(maxBatchSize: 100, flushInterval: 60,
                                                               aggregation: configuration), transport: transport)
            await exporter.timer("first", duration: 0.001)
            await exporter.timer("first", duration: 0.002)
            await exporter.timer("second", duration: 0.003)
            await exporter.forceFlush()
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            XCTAssertEqual(packets.sorted(), ["first:1.0|ms", "first:2.0|ms", "second:3.0|ms"])
            await exporter.close()
        }
    }

    func testAggregationUsesEffectiveGlobalTagsForLatestGauge() async throws {
        for explicitTagsFirst in [false, true] {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                globalTags: ["tenant": "a"], flushInterval: 60,
                aggregation: .init(enabled: true, flushInterval: 60)
            ), transport: transport)
            await exporter.gauge("latest", value: 1, tags: explicitTagsFirst ? ["tenant": "a"] : [:])
            await exporter.gauge("latest", value: 2, tags: explicitTagsFirst ? [:] : ["tenant": "a"])
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            XCTAssertEqual(packets, ["latest:2.0|g|#tenant:a"])
            await exporter.close()
        }
    }

    func testEmptyMetricNameIsRejected() async throws {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: .init(maxBatchSize: 1), transport: transport)
        let failures = Mutex(0)
        await exporter.setErrorHandler { error in
            if case MetricsError.invalidData = error { failures.withLock { $0 += 1 } }
        }
        await exporter.counter("")
        let packets = await transport.getMetricsAsStrings()
        XCTAssertTrue(packets.isEmpty)
        XCTAssertEqual(failures.withLock { $0 }, 1)
        await exporter.close()
    }

    func testNonfiniteValuesAreRejectedWithoutPoisoningPendingMetrics() async throws {
        for aggregationEnabled in [false, true] {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                maxBatchSize: 100, flushInterval: 60,
                aggregation: .init(enabled: aggregationEnabled, flushInterval: 60)
            ), transport: transport)
            let failures = Mutex(0)
            await exporter.setErrorHandler { error in
                if case MetricsError.invalidData = error { failures.withLock { $0 += 1 } }
            }
            await exporter.counter("valid", value: 3)
            for type in ["counter", "gauge", "timer", "histogram"] {
                for value in [Double.nan, .infinity, -.infinity] {
                    await exporter.record(.init(name: "invalid", type: type, value: value))
                }
            }
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            XCTAssertEqual(packets, ["valid:3.0|c"])
            XCTAssertEqual(failures.withLock { $0 }, 12)
            await exporter.close()
        }
    }

    func testAggregateOverflowRejectsIncomingValueAndRetainsPreviousCounter() async throws {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: .init(
            flushInterval: 60, aggregation: .init(enabled: true, flushInterval: 60)
        ), transport: transport)
        let failures = Mutex(0)
        await exporter.setErrorHandler { error in
            if case MetricsError.invalidData = error { failures.withLock { $0 += 1 } }
        }
        await exporter.counter("large", value: Double.greatestFiniteMagnitude)
        await exporter.counter("large", value: Double.greatestFiniteMagnitude)
        await exporter.forceFlush()
        let packets = await transport.getMetricsAsStrings()
        XCTAssertEqual(packets, ["large:1.7976931348623157e+308|c"])
        XCTAssertEqual(failures.withLock { $0 }, 1)
        await exporter.close()
    }

    func testAggregatorRejectsUnrepresentableSamplingCompensation() throws {
        var aggregator = MetricAggregator(configuration: .init(enabled: true))
        XCTAssertThrowsError(try aggregator.aggregate(.counter("overflow"), sampleRate: .leastNonzeroMagnitude))
        XCTAssertTrue(aggregator.flush().isEmpty)
    }

    func testCancelledTimerCannotFlushNextGeneration() async throws {
        for aggregationEnabled in [false, true] {
            let sleeper = ControlledMetricSleeper()
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                maxBatchSize: 100, flushInterval: 60,
                aggregation: .init(enabled: aggregationEnabled, flushInterval: 60, flushJitter: 0)
            ), transport: transport, sleep: { try await sleeper.sleep($0) })
            await exporter.counter("generation.first")
            await sleeper.waitForCount(1)
            let oldTimers = await exporter.timerTasks
            let oldID = try XCTUnwrap(oldTimers.keys.first)
            let oldTimer = try XCTUnwrap(oldTimers[oldID])
            await exporter.forceFlush()
            await exporter.counter("generation.second")
            await sleeper.waitForCount(2)
            let nextTimers = await exporter.timerTasks
            let nextTimer = try XCTUnwrap(nextTimers.first { $0.key != oldID }?.value)
            await sleeper.release(1)
            await oldTimer.value
            let before = await transport.getMetricsAsStrings()
            XCTAssertEqual(before, ["generation.first:1.0|c"])
            await sleeper.release(2)
            await nextTimer.value
            let after = await transport.getMetricsAsStrings()
            XCTAssertEqual(after, ["generation.first:1.0|c", "generation.second:1.0|c"])
            await exporter.close()
        }
    }

    func testCloseJoinsCancelledAggregationTimerAndDiscardsPendingSamples() async throws {
        let sleeper = ControlledMetricSleeper()
        let transport = TelemetryPacketTransport(onSend: {})
        let exporter = StatsDExporter(configuration: .init(
            aggregation: .init(enabled: true, flushInterval: 60, flushJitter: 0)
        ), transport: transport, sleep: { try await sleeper.sleep($0) })
        await exporter.counter("discarded")
        await sleeper.waitForCount(1)
        let closed = Mutex(0)
        let firstClose = Task { await exporter.close(); closed.withLock { $0 += 1 } }
        let secondClose = Task { await exporter.close(); closed.withLock { $0 += 1 } }
        while !(await exporter.isClosed) { await Task.yield() }
        XCTAssertEqual(closed.withLock { $0 }, 0)
        await sleeper.release(1)
        await firstClose.value
        await secondClose.value
        let packets = await transport.packets
        let timers = await exporter.timerTasks.count
        XCTAssertTrue(packets.isEmpty)
        XCTAssertEqual(timers, 0)
        XCTAssertEqual(closed.withLock { $0 }, 2)
    }

    func testSleepingAggregationTimerDoesNotRetainExporter() async throws {
        let sleeper = ControlledMetricSleeper()
        let transport = TelemetryPacketTransport(onSend: {})
        var exporter: StatsDExporter? = StatsDExporter(configuration: .init(
            aggregation: .init(enabled: true, flushInterval: 60, flushJitter: 0)
        ), transport: transport, sleep: { try await sleeper.sleep($0) })
        weak var weakExporter = exporter
        await exporter?.counter("unowned")
        await sleeper.waitForCount(1)
        let timers = await exporter?.timerTasks.values.map { $0 } ?? []
        exporter = nil
        XCTAssertNil(weakExporter)
        await sleeper.release(1)
        for timer in timers { await timer.value }
        let packets = await transport.packets
        XCTAssertTrue(packets.isEmpty)
    }

    func testTransportSendCanReenterCloseWhileExternalCloseJoinsSettlement() async {
        let returned = expectation(description: "reentrant close returns to transport send")
        let transport = ReentrantTelemetryTransport(fromSend: true, returned: { returned.fulfill() })
        let exporter = StatsDExporter(configuration: .init(maxBatchSize: 100, flushInterval: 0), transport: transport)
        await transport.install(exporter)
        await exporter.counter("reentrant")
        await transport.waitForCloseEntry()
        await fulfillment(of: [returned], timeout: 1)
        guard await transport.didReturn else { await transport.releaseClose(); return }
        let finished = Mutex(false)
        let externalClose = Task { await exporter.close(); finished.withLock { $0 = true } }
        XCTAssertFalse(finished.withLock { $0 })
        await transport.releaseClose()
        await externalClose.value
        let closes = await transport.closeCount
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(finished.withLock { $0 })
        await transport.uninstall()
    }

    func testTransportCloseCanReenterClose() async {
        let returned = expectation(description: "transport close reentry returns")
        let transport = ReentrantTelemetryTransport(fromSend: false, returned: { returned.fulfill() })
        let exporter = StatsDExporter(configuration: .default, transport: transport)
        await transport.install(exporter)
        let closing = Task { await exporter.close() }
        await fulfillment(of: [returned], timeout: 1)
        guard await transport.didReturn else { await transport.releaseClose(); return }
        await transport.releaseClose()
        await closing.value
        let closes = await transport.closeCount
        XCTAssertEqual(closes, 1)
        await transport.uninstall()
    }

    func testNegativeAbsoluteGaugeResetAndValueShareOneDatagram() async throws {
        for aggregationEnabled in [false, true] {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                maxBatchSize: 1, flushInterval: 60,
                aggregation: .init(enabled: aggregationEnabled, flushInterval: 60)
            ), transport: transport)
            await exporter.gauge("temperature", value: -5, tags: ["room": "lab"])
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            XCTAssertEqual(packets, ["temperature:0.0|g|#room:lab\ntemperature:-5.0|g|#room:lab"])
            await exporter.close()
        }
    }

    func testMetricNamesAndPrefixCannotInjectDatagramLines() async throws {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: .init(prefix: "prefix\ninjected:1|c", maxBatchSize: 1),
                                      transport: transport)
        await exporter.gauge("name\r\nline", value: 7, tags: ["tag": "x:y"])
        let packets = await transport.getMetricsAsStrings()
        XCTAssertEqual(packets, ["prefix_injected_1_c.name__line:7.0|g|#tag:x:y"])
        await exporter.close()
    }

    func testMalformedTagsAreRejectedWithoutPackets() async throws {
        let malformedTags = [["": "value"], ["key:part": "value"], ["key,part": "value"],
                             ["key|part": "value"], ["key\npart": "value"], ["key\rpart": "value"],
                             ["key": "value,part"], ["key": "value|part"],
                             ["key": "value\npart"], ["key": "value\rpart"]]
        for aggregationEnabled in [false, true] {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                maxBatchSize: 1, flushInterval: 60,
                aggregation: .init(enabled: aggregationEnabled, flushInterval: 60)
            ), transport: transport)
            let failures = Mutex<Int>(0)
            await exporter.setErrorHandler { error in
                if case MetricsError.invalidData = error { failures.withLock { $0 += 1 } }
            }
            for tags in malformedTags { await exporter.counter("safe", tags: tags) }
            await exporter.forceFlush()
            let packets = await transport.getMetricsAsStrings()
            XCTAssertTrue(packets.isEmpty)
            XCTAssertEqual(failures.withLock { $0 }, malformedTags.count)
            await exporter.close()
        }
    }

    func testSampledCountersReceiveExactlyOneCompensationOnWire() async throws {
        for aggregationEnabled in [false, true] {
            let transport = try await MockTransport(configuration: .init())
            let exporter = StatsDExporter(configuration: .init(
                maxBatchSize: 1000,
                flushInterval: 60,
                sampleRate: 0.25,
                criticalPatterns: [],
                aggregation: .init(enabled: aggregationEnabled, flushInterval: 60)
            ), transport: transport)
            for index in 0..<100 {
                let name = "sample.counter.\(index)"
                await exporter.record(.init(name: name, type: "counter"))
                await exporter.counter(name, value: 3)
            }
            await exporter.forceFlush()
            let lines = await transport.getMetricsAsStrings()
            XCTAssertFalse(lines.isEmpty)
            var receiverTotals: [String: Double] = [:]
            for line in lines {
                let fields = line.split(separator: "|")
                let nameAndValue = fields[0].split(separator: ":", maxSplits: 1)
                let name = String(nameAndValue[0])
                let value = try XCTUnwrap(Double(nameAndValue[1]))
                let rate = try fields.first(where: { $0.hasPrefix("@") })
                    .map { try XCTUnwrap(Double($0.dropFirst())) } ?? 1
                receiverTotals[name, default: 0] += value / rate
            }
            for total in receiverTotals.values {
                // Retained increment 1 + explicit amount 3, sampled at 1/4.
                XCTAssertEqual(total, 16, accuracy: 0.000_001)
            }
            await exporter.close()
        }
    }

    func testAggregationIntervalTransmitsPendingMetrics() async throws {
        let delivered = expectation(description: "aggregation interval delivers counter")
        let transport = TelemetryPacketTransport(onSend: { delivered.fulfill() })
        let exporter = StatsDExporter(configuration: .init(
            maxBatchSize: 100,
            flushInterval: 60,
            aggregation: .init(enabled: true, flushInterval: 0.01, flushJitter: 0)
        ), transport: transport)
        await exporter.counter("interval.counter", value: 7)
        await fulfillment(of: [delivered], timeout: 2)
        await exporter.forceFlush()
        let packets = await transport.packets
        XCTAssertEqual(packets, ["interval.counter:7.0|c"])
        await exporter.close()
    }

    func testAggregationPreservesExactTagsWithoutDelimiterCollisions() async throws {
        var aggregator = MetricAggregator(configuration: .init(enabled: true, flushInterval: 60))
        let tagSets = [
            ["a": "b,c:d"],
            ["a": "b", "c": "d"],
            ["": "empty-key", "empty-value": "", "colon:key": "colon:value"]
        ]
        for (index, tags) in tagSets.enumerated() {
            _ = try aggregator.aggregate(.counter("same", value: Double(index + 1), tags: tags), sampleRate: 1)
        }
        let output = aggregator.forceFlush()
        XCTAssertEqual(output.count, 3)
        for (index, tags) in tagSets.enumerated() {
            let matches = output.filter { $0.0.tags == tags }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.0.value ?? -1, Double(index + 1), accuracy: 0.000_001)
        }
    }

    func testAggregationKeepsKindsAndUnitsSeparate() async throws {
        var aggregator = MetricAggregator(configuration: .init(enabled: true, flushInterval: 60))
        let snapshots: [MetricSnapshot] = [
            .init(name: "same", type: "counter", value: 2),
            .init(name: "same", type: "gauge", value: 3, unit: "bytes"),
            .init(name: "same", type: "gauge", value: 4, unit: "items"),
            .init(name: "same", type: "timer", value: 5, unit: "ms"),
            .init(name: "same", type: "histogram", value: 6, unit: "bytes")
        ]
        for snapshot in snapshots { _ = try aggregator.aggregate(snapshot, sampleRate: 1) }
        let output = aggregator.forceFlush()
        XCTAssertEqual(output.count, 5)
        for snapshot in snapshots {
            let matches = output.filter { $0.0.type == snapshot.type && $0.0.unit == snapshot.unit }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.0.value ?? -1, snapshot.value ?? -2, accuracy: 0.000_001)
        }
    }

    func testAggregatedObservationsRetainSamplingRate() async throws {
        var aggregator = MetricAggregator(configuration: .init(enabled: true, flushInterval: 60))
        for type in ["timer", "histogram"] {
            _ = try aggregator.aggregate(.init(name: type, type: type, value: 7), sampleRate: 0.25)
        }
        let output = aggregator.forceFlush()
        XCTAssertEqual(output.count, 2)
        for (snapshot, rate) in output {
            XCTAssertEqual(snapshot.value ?? -1, 7, accuracy: 0.000_001)
            XCTAssertEqual(rate, 0.25, accuracy: 0.000_001)
        }
    }

    func testCapacityAllowsUpdatesThatDoNotAddStoredValues() async throws {
        var aggregator = MetricAggregator(configuration: .init(enabled: true, maxTotalValues: 2))
        _ = try aggregator.aggregate(.counter("counter"), sampleRate: 1)
        _ = try aggregator.aggregate(.gauge("gauge", value: 2), sampleRate: 1)
        let counterAccepted = try aggregator.aggregate(.counter("counter", value: 3), sampleRate: 1)
        let gaugeAccepted = try aggregator.aggregate(.gauge("gauge", value: 5), sampleRate: 1)
        XCTAssertTrue(counterAccepted)
        XCTAssertTrue(gaugeAccepted)
        let output = aggregator.forceFlush()
        XCTAssertEqual(output.first { $0.0.type == "counter" }?.0.value ?? -1, 4, accuracy: 0.000_001)
        XCTAssertEqual(output.first { $0.0.type == "gauge" }?.0.value ?? -1, 5, accuracy: 0.000_001)
    }
}

private actor TelemetryPacketTransport: MetricsTransport {
    struct Configuration: Sendable {}
    private let onSend: @Sendable () -> Void
    private(set) var packets: [String] = []
    init(onSend: @escaping @Sendable () -> Void) { self.onSend = onSend }
    init(configuration: Configuration) async throws { onSend = {} }
    func send(_ data: Data) async throws {
        packets.append(String(decoding: data, as: UTF8.self))
        onSend()
    }
    func sendBatch(_ batch: [Data]) async throws {
        for packet in batch { try await send(packet) }
    }
    func close() async {}
}

private actor ControlledMetricSleeper {
    private var count = 0
    private(set) var intervals: [TimeInterval] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(_ interval: TimeInterval) async throws {
        await withCheckedContinuation { continuation in
            count += 1
            intervals.append(interval)
            pending[count] = continuation
        }
    }

    func waitForCount(_ expected: Int) async {
        while count < expected { await Task.yield() }
    }

    func release(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
}

private actor ReentrantTelemetryTransport: MetricsTransport {
    struct Configuration: Sendable {}
    private let fromSend: Bool
    private let returned: @Sendable () -> Void
    private var exporter: StatsDExporter?
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var closeReleased = false
    private(set) var didReturn = false
    private(set) var closeCount = 0
    init(fromSend: Bool, returned: @escaping @Sendable () -> Void) {
        self.fromSend = fromSend
        self.returned = returned
    }
    init(configuration: Configuration) async throws { fromSend = false; returned = {} }
    func install(_ exporter: StatsDExporter) { self.exporter = exporter }
    func uninstall() { exporter = nil }
    func send(_ data: Data) async throws {
        if fromSend {
            await exporter?.close()
            didReturn = true
            returned()
        }
    }
    func sendBatch(_ batch: [Data]) async throws {
        for packet in batch { try await send(packet) }
    }
    func close() async {
        closeCount += 1
        if !fromSend {
            await exporter?.close()
            didReturn = true
            returned()
        }
        if !closeReleased { await withCheckedContinuation { closeWaiter = $0 } }
    }
    func waitForCloseEntry() async {
        while closeCount == 0 { await Task.yield() }
    }
    func releaseClose() {
        closeReleased = true
        closeWaiter?.resume()
        closeWaiter = nil
    }
}

private actor SendSettlingTelemetryTransport: MetricsTransport {
    struct Configuration: Sendable {}
    private var exporter: StatsDExporter?
    private var sending = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let returned: @Sendable () -> Void
    private(set) var didReturn = false
    private(set) var closeCount = 0
    init(returned: @escaping @Sendable () -> Void) { self.returned = returned }
    init(configuration: Configuration) async throws { returned = {} }
    func install(_ exporter: StatsDExporter) { self.exporter = exporter }
    func uninstall() { exporter = nil }
    func send(_ data: Data) async throws {
        sending = true
        await exporter?.close()
        sending = false
        waiter?.resume()
        waiter = nil
        didReturn = true
        returned()
    }
    func sendBatch(_ batch: [Data]) async throws {
        for packet in batch { try await send(packet) }
    }
    func close() async {
        closeCount += 1
        if sending { await withCheckedContinuation { waiter = $0 } }
    }
}

private actor DescendantCloseTelemetryTransport: MetricsTransport {
    struct Configuration: Sendable {}
    private var exporter: StatsDExporter?
    private let completed: @Sendable () -> Void
    private var child: Task<Void, Never>?
    private var childWaiter: CheckedContinuation<Void, Never>?
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var sent = false
    private var closing = false
    private var childReleased = false
    private var closeReleased = false
    init(completed: @escaping @Sendable () -> Void) { self.completed = completed }
    init(configuration: Configuration) async throws { completed = {} }
    func install(_ exporter: StatsDExporter) { self.exporter = exporter }
    func uninstall() { exporter = nil; child = nil }
    func send(_ data: Data) async throws {
        let exporter = exporter
        child = Task {
            if !childReleased { await withCheckedContinuation { childWaiter = $0 } }
            await exporter?.close()
            completed()
        }
        sent = true
    }
    func sendBatch(_ batch: [Data]) async throws {
        for packet in batch { try await send(packet) }
    }
    func close() async {
        closing = true
        if !closeReleased { await withCheckedContinuation { closeWaiter = $0 } }
    }
    func waitForSend() async { while !sent { await Task.yield() } }
    func waitForClose() async { while !closing { await Task.yield() } }
    func releaseChild() { childReleased = true; childWaiter?.resume(); childWaiter = nil }
    func releaseClose() { closeReleased = true; closeWaiter?.resume(); closeWaiter = nil }
    func joinChild() async { await child?.value }
}
