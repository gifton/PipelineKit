import Foundation
import Synchronization
import XCTest
import PipelineKit
import PipelineKitCore
import PipelineKitTestSupport
@testable import _CircuitBreaker

@MainActor
final class HealthRecoveryContractTests: XCTestCase {
    private enum Observation: CaseIterable {
        case singleStatus, allStatuses, admission
    }

    func testBlockedServiceRecoversWhenFailureWindowExpires() async {
        for minimum in [1, 10] {
            for observation in Observation.allCases {
                let clock = HealthTestClock()
                let middleware = makeMiddleware(clock: clock, minimum: minimum)
                for _ in 0..<minimum {
                    await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
                }
                await assertRequest(middleware, outcome: .blocked("service"), entered: false)

                clock.set(10.nextUp)
                if observation != .admission {
                    let status = await readStatus(middleware, observation: observation)
                    assertEmpty(status, state: .unknown)
                    // Read the other public API too, after the independently selected first observer.
                    let other = await readStatus(middleware, observation: observation == .singleStatus ? .allStatuses : .singleStatus)
                    assertEmpty(other, state: .unknown)
                }
                await assertRequest(middleware, outcome: .succeeded(42), entered: true, state: .unknown)
                let recovered = await middleware.getHealthStatus(for: "service")
                XCTAssertEqual(recovered.totalRequests, 1)
                XCTAssertEqual(recovered.recentFailures, 0)
                XCTAssertEqual(recovered.state, minimum == 1 ? .healthy : .unknown)
            }
        }
    }

    func testRequestWindowIncludesCutoffAndExpiresImmediatelyAfterIt() async {
        for minimum in [1, 10] {
            for observation in [Observation.singleStatus, .allStatuses] {
                let clock = HealthTestClock()
                let middleware = makeMiddleware(clock: clock, minimum: minimum)
                for _ in 0..<minimum {
                    await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
                }
                for instant in [10.nextDown, 10] {
                    clock.set(instant)
                    let status = await readStatus(middleware, observation: observation)
                    XCTAssertEqual(status.state, .unhealthy)
                    XCTAssertEqual(status.totalRequests, minimum)
                    XCTAssertEqual(status.recentFailures, minimum)
                    await assertRequest(middleware, outcome: .blocked("service"), entered: false)
                }
                clock.set(10.nextUp)
                let expired = await readStatus(middleware, observation: observation)
                assertEmpty(expired, state: .unknown)
            }
        }
    }

    func testFreshUnhealthyProbeStillBlocksAndStaleProbeDoesNot() async {
        await exerciseProbeFreshness(.unhealthy)
    }

    func testHealthyDegradedAndUnknownProbeFreshnessAndAdmission() async {
        for state in [HealthCheckMiddleware.HealthState.healthy, .degraded, .unknown] {
            await exerciseProbeFreshness(state)
        }
    }

    private func exerciseProbeFreshness(_ probeState: HealthCheckMiddleware.HealthState) async {
        for minimum in [1, 10] {
            for observation in Observation.allCases {
                // A probe is fresh strictly before its deadline, including the preceding representable Date.
                for (instant, expected) in [(20.nextDown, probeState), (20.0, .unknown), (20.nextUp, .unknown)] {
                    let clock = HealthTestClock()
                    let probe = FixedHealthProbe(result: .init(status: probeState, timestamp: clock.date))
                    let middleware = makeMiddleware(clock: clock, minimum: minimum, probe: probe)
                    let result = await middleware.checkHealth(for: "service")
                    XCTAssertEqual(result.status, probeState)
                    clock.set(instant)
                    if observation != .admission {
                        let status = await readStatus(middleware, observation: observation)
                        assertEmpty(status, state: expected)
                        XCTAssertEqual(status.lastCheck, Date(timeIntervalSinceReferenceDate: 0))
                    }
                    let blocked = expected == .unhealthy
                    await assertRequest(middleware, outcome: blocked ? .blocked("service") : .succeeded(42),
                                        entered: !blocked, state: expected)
                }
            }
        }
    }

    func testHealthyProbeDoesNotOverrideSufficientRecentFailures() async {
        for minimum in [1, 10] {
            let clock = HealthTestClock()
            let probe = FixedHealthProbe(result: .init(status: .healthy, timestamp: Date(timeIntervalSinceReferenceDate: 1)))
            let middleware = makeMiddleware(clock: clock, minimum: minimum, probe: probe)
            for _ in 0..<minimum {
                await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
            }
            clock.set(1)
            let result = await middleware.checkHealth(for: "service")
            XCTAssertEqual(result.status, .healthy)
            let stillUnhealthy = await middleware.getHealthStatus(for: "service")
            XCTAssertEqual(stillUnhealthy.state, .unhealthy)
            XCTAssertEqual(stillUnhealthy.totalRequests, minimum)
            await assertRequest(middleware, outcome: .blocked("service"), entered: false)

            clock.set(10.nextUp)
            let freshProbe = await middleware.getHealthStatus(for: "service")
            assertEmpty(freshProbe, state: .healthy)
            await assertRequest(middleware, outcome: .succeeded(42), entered: true, state: .healthy)
            clock.set(21)
            let expired = await middleware.getHealthStatus(for: "service")
            assertEmpty(expired, state: .unknown)
            await assertRequest(middleware, outcome: .succeeded(42), entered: true, state: .unknown)
        }
    }

    func testPartiallyExpiredWindowUsesFreshProbeOrUnknown() async {
        for hasProbe in [false, true] {
            for observation in Observation.allCases {
                let clock = HealthTestClock()
                let probe = FixedHealthProbe(result: .init(status: .unhealthy, timestamp: Date(timeIntervalSinceReferenceDate: 5)))
                let middleware = makeMiddleware(clock: clock, minimum: 10, probe: hasProbe ? probe : nil)
                for _ in 0..<9 {
                    await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
                }
                clock.set(5)
                await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
                if hasProbe { _ = await middleware.checkHealth(for: "service") }
                clock.set(10.nextUp)
                let expected: HealthCheckMiddleware.HealthState = hasProbe ? .unhealthy : .unknown
                if observation != .admission {
                    let status = await readStatus(middleware, observation: observation)
                    XCTAssertEqual(status.state, expected)
                    XCTAssertEqual(status.totalRequests, 1)
                    XCTAssertEqual(status.recentFailures, 1)
                }
                // A failed downstream reentry is recorded too; fewer than ten samples remain.
                await assertRequest(middleware, succeeds: false, outcome: hasProbe ? .blocked("service") : .failed,
                                    entered: !hasProbe, state: expected)
                clock.set(25)
                await assertRequest(middleware, outcome: .succeeded(42), entered: true, state: .unknown)
            }
        }
    }

    func testProbeExpiryWithSufficientSuccessfulRequests() async {
        for minimum in [1, 10] {
            for observation in Observation.allCases {
                for state in [HealthCheckMiddleware.HealthState.unhealthy, .degraded] {
                    for (instant, expected) in [(20.nextDown, state), (20.0, .healthy), (20.nextUp, .healthy)] {
                        let clock = HealthTestClock()
                        let probe = FixedHealthProbe(result: .init(status: state, timestamp: clock.date))
                        let middleware = makeMiddleware(clock: clock, minimum: minimum, window: 100, probe: probe)
                        for _ in 0..<minimum {
                            await assertRequest(middleware, outcome: .succeeded(42), entered: true)
                        }
                        _ = await middleware.checkHealth(for: "service")
                        clock.set(instant)
                        if observation != .admission {
                            let status = await readStatus(middleware, observation: observation)
                            XCTAssertEqual(status.state, expected)
                            XCTAssertEqual(status.totalRequests, minimum)
                        }
                        let blocked = expected == .unhealthy
                        await assertRequest(middleware, outcome: blocked ? .blocked("service") : .succeeded(42),
                                            entered: !blocked, state: expected)
                    }
                }
            }
        }
    }

    func testSuccessThresholdAppliesWhileUnhealthyHasSufficientCurrentRequests() async {
        for minimum in [1, 10] {
            let clock = HealthTestClock()
            let middleware = makeMiddleware(clock: clock, minimum: minimum, successThreshold: 3)
            let gate = TestSynchronizer()
            // Admit these before failure closes admission, then settle them one at a time.
            let held = (0..<3).map { index in
                Task { await self.request(middleware, gate: gate, id: String(index)) }
            }
            for index in 0..<3 { await gate.wait(for: "entered-\(index)") }
            for _ in 0..<minimum {
                await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
            }
            await assertRequest(middleware, outcome: .blocked("service"), entered: false)
            for index in 0..<3 {
                await gate.signal("release-\(index)")
                let settled = await held[index].value
                XCTAssertEqual(settled.outcome, .succeeded(42))
                XCTAssertTrue(settled.entered)
                let status = await middleware.getHealthStatus(for: "service")
                XCTAssertEqual(status.totalRequests, minimum + index + 1)
                XCTAssertEqual(status.state, index == 2 ? .healthy : .unhealthy)
                if index < 2 {
                    await assertRequest(middleware, outcome: .blocked("service"), entered: false)
                }
            }
            await assertRequest(middleware, outcome: .succeeded(42), entered: true, state: .healthy)
        }
    }

    func testExpiredFailuresDoNotContributeToNewConsecutiveFailureRun() async {
        let clock = HealthTestClock()
        let middleware = makeMiddleware(clock: clock, failureThreshold: 3, block: false)
        for _ in 0..<2 {
            await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
        }
        clock.set(10.nextUp)
        await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
        let status = await middleware.getHealthStatus(for: "service")
        XCTAssertEqual(status.state, .healthy)
        XCTAssertEqual(status.totalRequests, 1)
        XCTAssertEqual(status.recentFailures, 1)
    }

    func testExpiredSuccessesDoNotSatisfyRecoveryThreshold() async {
        for observation in [Observation.singleStatus, .allStatuses] {
            let clock = HealthTestClock()
            let middleware = makeMiddleware(clock: clock, successThreshold: 3, block: false)
            await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
            await assertRequest(middleware, outcome: .succeeded(42), entered: true)
            clock.set(5)
            await assertRequest(middleware, outcome: .succeeded(42), entered: true)
            clock.set(10.nextUp)
            let status = await readStatus(middleware, observation: observation)
            XCTAssertEqual(status.state, .unhealthy)
            XCTAssertEqual(status.totalRequests, 1)
            await assertRequest(middleware, outcome: .succeeded(42), entered: true)
            let belowThreshold = await middleware.getHealthStatus(for: "service")
            XCTAssertEqual(belowThreshold.state, .unhealthy)
            XCTAssertEqual(belowThreshold.totalRequests, 2)
            await assertRequest(middleware, outcome: .succeeded(42), entered: true)
            let recovered = await middleware.getHealthStatus(for: "service")
            XCTAssertEqual(recovered.state, .healthy)
        }
    }

    func testProbeCompletionPrunesHistoryAndNotifiesBeforeAnotherQuery() async {
        for minimum in [1, 10] {
            let clock = HealthTestClock()
            let gate = TestSynchronizer()
            let recovered = expectation(description: "Probe completion reports recovery for minimum \(minimum)")
            let middleware = makeMiddleware(clock: clock, minimum: minimum,
                probe: HeldHealthProbe(clock: clock, gate: gate), onChange: { service, old, new in
                    if service == "service" && old == .unhealthy && new == .healthy { recovered.fulfill() }
                })
            for _ in 0..<minimum {
                await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
            }
            let check = Task { await middleware.checkHealth(for: "service") }
            await gate.wait(for: "probe-entered")
            clock.set(10.nextUp)
            let previousReads = clock.reads
            await gate.signal("probe-release")
            let result = await check.value
            XCTAssertEqual(result.status, .healthy)
            XCTAssertEqual(clock.reads - previousReads, 1)
            await fulfillment(of: [recovered], timeout: 1)
            let status = await middleware.getHealthStatus(for: "service")
            assertEmpty(status, state: .healthy)
            await assertRequest(middleware, outcome: .succeeded(42), entered: true, state: .healthy)
        }
    }

    func testEveryRecoveryObservationNotifiesStateChanges() async {
        for observation in Observation.allCases {
            let clock = HealthTestClock()
            let unhealthy = expectation(description: "Initial failure notification")
            let unknown = expectation(description: "Expired evidence notification")
            let healthy = expectation(description: "Successful reentry notification")
            let transitions = HealthTransitionLog()
            let middleware = makeMiddleware(clock: clock, onChange: { service, old, new in
                transitions.append(service: service, old: old, new: new)
                switch (old, new) {
                case (.unknown, .unhealthy): unhealthy.fulfill()
                case (.unhealthy, .unknown): unknown.fulfill()
                case (.unknown, .healthy): healthy.fulfill()
                default: break
                }
            })
            await assertRequest(middleware, succeeds: false, outcome: .failed, entered: true)
            await fulfillment(of: [unhealthy], timeout: 1)
            clock.set(10.nextUp)
            if observation != .admission {
                let status = await readStatus(middleware, observation: observation)
                assertEmpty(status, state: .unknown)
            }
            await assertRequest(middleware, outcome: .succeeded(42), entered: true, state: .unknown)
            await fulfillment(of: [unknown, healthy], timeout: 1)
            XCTAssertEqual(transitions.values.sorted(), ["service:unknown->unhealthy", "service:unhealthy->unknown", "service:unknown->healthy"].sorted())
        }
    }

    func testEachStatusSnapshotCapturesOneClockValue() async {
        let clock = HealthTestClock()
        let middleware = makeMiddleware(clock: clock)
        for service in ["a", "b"] {
            await assertRequest(middleware, service: service, succeeds: false, outcome: .failed, entered: true)
        }
        clock.set(10, advancePerRead: 1)
        var before = clock.reads
        let statuses = await middleware.getHealthStatus()
        XCTAssertEqual(clock.reads - before, 1)
        XCTAssertEqual(statuses.count, 2)
        for service in ["a", "b"] {
            XCTAssertEqual(statuses[service]?.state, .unhealthy)
            XCTAssertEqual(statuses[service]?.totalRequests, 1)
        }
        clock.set(10, advancePerRead: 1)
        before = clock.reads
        let single = await middleware.getHealthStatus(for: "a")
        XCTAssertEqual(clock.reads - before, 1)
        XCTAssertEqual(single.state, .unhealthy)
        XCTAssertEqual(single.totalRequests, 1)

        clock.set(10.nextUp)
        before = clock.reads
        await assertRequest(middleware, service: "a", outcome: .succeeded(42), entered: true, state: .unknown)
        // Admission and completion are distinct evaluations, each captures once.
        XCTAssertEqual(clock.reads - before, 2)
        before = clock.reads
        await assertRequest(middleware, service: "b", outcome: .succeeded(42), entered: true, state: .unknown)
        XCTAssertEqual(clock.reads - before, 2)
    }

    private func makeMiddleware(
        clock: HealthTestClock, minimum: Int = 1, failureThreshold: Int = 1, window: TimeInterval = 10,
        successThreshold: Int = 1, block: Bool = true, probe: (any HealthCheck)? = nil,
        onChange: (@Sendable (String, HealthCheckMiddleware.HealthState, HealthCheckMiddleware.HealthState) async -> Void)? = nil
    ) -> HealthCheckMiddleware {
        HealthCheckMiddleware(configuration: .init(checkInterval: 10, failureThreshold: failureThreshold,
            successThreshold: successThreshold, windowSize: window, minRequests: minimum, successRateThreshold: 0,
            healthChecks: probe.map { ["service": $0] } ?? [:], stateChangeHandler: onChange,
            emitMetrics: false, blockUnhealthyServices: block),
            now: { clock.now() }, startPeriodicHealthChecks: false)
    }

    private func readStatus(_ middleware: HealthCheckMiddleware, observation: Observation) async -> HealthStatus {
        switch observation {
        case .singleStatus, .admission: return await middleware.getHealthStatus(for: "service")
        case .allStatuses:
            let statuses = await middleware.getHealthStatus()
            XCTAssertNotNil(statuses["service"])
            return statuses["service"] ?? HealthStatus(state: .unknown, successRate: 0,
                averageResponseTime: 0, totalRequests: -1, recentFailures: -1, lastCheck: nil)
        }
    }

    private func assertEmpty(_ status: HealthStatus, state: HealthCheckMiddleware.HealthState,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(status.state, state, file: file, line: line)
        XCTAssertEqual(status.totalRequests, 0, file: file, line: line)
        XCTAssertEqual(status.recentFailures, 0, file: file, line: line)
        XCTAssertEqual(status.successRate, 0, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(status.averageResponseTime, 0, accuracy: 0.000001, file: file, line: line)
    }

    private func assertRequest(_ middleware: HealthCheckMiddleware, service: String = "service", succeeds: Bool = true,
                               outcome: HealthRequestOutcome, entered: Bool, state: HealthCheckMiddleware.HealthState? = nil,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let result = await request(middleware, service: service, succeeds: succeeds)
        XCTAssertEqual(result.outcome, outcome, file: file, line: line)
        XCTAssertEqual(result.entered, entered, file: file, line: line)
        if let state { XCTAssertEqual(result.state, state.rawValue, file: file, line: line) }
    }

    private func request(_ middleware: HealthCheckMiddleware, service: String = "service", succeeds: Bool = true,
                         gate: TestSynchronizer? = nil, id: String = "") async -> HealthRequestObservation {
        let entry = HealthEntryFlag()
        let context = CommandContext()
        let outcome: HealthRequestOutcome
        do {
            let result = try await middleware.execute(HealthTestCommand(serviceName: service), context: context) { _, _ in
                entry.markEntered()
                if let gate {
                    await gate.signal("entered-\(id)")
                    await gate.wait(for: "release-\(id)")
                }
                if !succeeds { throw HealthFixtureError.failed }
                return 42
            }
            outcome = .succeeded(result)
        } catch HealthFixtureError.failed {
            outcome = .failed
        } catch PipelineError.middlewareError(let middleware, _, let errorContext) where middleware == "HealthCheckMiddleware" {
            outcome = .blocked(errorContext?.additionalInfo["service"] ?? "missing service")
        } catch {
            outcome = .unexpected(String(describing: error))
        }
        return HealthRequestObservation(outcome: outcome, entered: entry.entered,
            state: context.getMetadata()["serviceHealth"] as? String)
    }
}

private struct HealthTestCommand: Command, ServiceIdentifiable {
    typealias Result = Int
    let serviceName: String
}

private enum HealthFixtureError: Error { case failed }
private enum HealthRequestOutcome: Equatable, Sendable {
    case succeeded(Int), failed, blocked(String), unexpected(String)
}
private struct HealthRequestObservation: Sendable {
    let outcome: HealthRequestOutcome
    let entered: Bool
    let state: String?
}

private final class HealthEntryFlag: Sendable {
    private let value = Mutex(false)
    func markEntered() { value.withLock { $0 = true } }
    var entered: Bool { value.withLock { $0 } }
}

private final class HealthTestClock: Sendable {
    private struct State {
        var date = Date(timeIntervalSinceReferenceDate: 0)
        var reads = 0
        var advancePerRead: TimeInterval = 0
    }
    private let state = Mutex(State())
    var date: Date { state.withLock { $0.date } }
    var reads: Int { state.withLock { $0.reads } }
    func now() -> Date {
        state.withLock { state in
            let result = state.date
            state.reads += 1
            state.date.addTimeInterval(state.advancePerRead)
            return result
        }
    }
    func set(_ instant: TimeInterval, advancePerRead: TimeInterval = 0) {
        state.withLock {
            $0.date = Date(timeIntervalSinceReferenceDate: instant)
            $0.advancePerRead = advancePerRead
        }
    }
}

private struct FixedHealthProbe: HealthCheck {
    let name = "fixed"
    let timeout: TimeInterval? = nil
    let result: HealthCheckResult
    func check() async -> HealthCheckResult { result }
}

private struct HeldHealthProbe: HealthCheck {
    let name = "held"
    let timeout: TimeInterval? = nil
    let clock: HealthTestClock
    let gate: TestSynchronizer
    func check() async -> HealthCheckResult {
        await gate.signal("probe-entered")
        await gate.wait(for: "probe-release")
        return .init(status: .healthy, timestamp: clock.date)
    }
}

private final class HealthTransitionLog: Sendable {
    private let storage = Mutex<[String]>([])
    var values: [String] { storage.withLock { $0 } }
    func append(service: String, old: HealthCheckMiddleware.HealthState, new: HealthCheckMiddleware.HealthState) {
        storage.withLock { $0.append("\(service):\(old.rawValue)->\(new.rawValue)") }
    }
}
