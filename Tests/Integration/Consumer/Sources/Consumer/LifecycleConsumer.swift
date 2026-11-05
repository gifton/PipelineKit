import Foundation
import Synchronization
import PipelineKit
import PipelineKitResilience
import PipelineKitObservability
import PipelineKitPooling

private final class LifecycleFlags: Sendable {
    struct State {
        var entered = false
        var cancelled = false
        var settled = false
        var released = false
        var stopReturned = false
    }
    let state = Mutex(State())
}

private final class LifecycleToken: Sendable {
    let flags: LifecycleFlags
    init(_ flags: LifecycleFlags) { self.flags = flags }
    deinit { flags.state.withLock { $0.released = true } }
}

private struct LifetimeHealthCheck: HealthCheck {
    let token: LifecycleToken
    let name = "consumer-lifetime"
    let timeout: TimeInterval? = nil
    func check() async -> HealthCheckResult {
        token.flags.state.withLock { $0.entered = true }
        return .healthy()
    }
}

private struct LifetimeRecorder: MetricRecorder {
    let token: LifecycleToken
    func record(_ snapshot: MetricSnapshot) async {
        token.flags.state.withLock { $0.entered = true }
    }
}

// Bounded observation only; callback entry/cancellation establish ordering.
private func observeLifecycle(_ message: String, until predicate: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate() {
        try require(ContinuousClock.now < deadline, message)
        await Task.yield()
    }
}

private enum LifecycleOwner: String, CaseIterable {
    case health, memory, metrics, poolCollector
}

// All owner kinds pass the same release assertion after this scope returns.
// No explicit shutdown may hide a background-task retain cycle in this matrix.
private func exerciseOwner(_ owner: LifecycleOwner) async throws -> LifecycleFlags {
    let flags = LifecycleFlags()
    let token = LifecycleToken(flags)
    switch owner {
    case .health:
        let middleware = HealthCheckMiddleware(configuration: .init(
            checkInterval: 60, healthChecks: ["consumer": LifetimeHealthCheck(token: token)]
        ))
        try await observeLifecycle("health check did not enter") { flags.state.withLock { $0.entered } }
        withExtendedLifetime(middleware) {}
    case .memory:
        let responder = MemoryPressureResponder()
        await responder.register { _ = token.flags.state.withLock { $0.entered } }
        await responder.startMonitoring()
        withExtendedLifetime(responder) {}
    case .metrics:
        let hub = EventHub()
        await hub.connectMetrics(LifetimeRecorder(token: token), config: .production)
        await hub.emit(lifecycleMetricEvent("consumer.owner"))
        try require(flags.state.withLock { $0.entered }, "connected recorder did not receive event")
        withExtendedLifetime(hub) {}
    case .poolCollector:
        let collector = PoolMetricsCollector(collectionInterval: 60)
        await collector.registerExporter { _ in token.flags.state.withLock { $0.entered = true } }
        await collector.startCollecting()
        try await observeLifecycle("pool collector did not enter exporter") { flags.state.withLock { $0.entered } }
        withExtendedLifetime(collector) {}
    }
    return flags
}

private actor LifecycleSettlementGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct SettlementHealthCheck: HealthCheck {
    let flags: LifecycleFlags
    let gate: LifecycleSettlementGate
    let name = "consumer-settlement"
    let timeout: TimeInterval? = nil
    func check() async -> HealthCheckResult {
        flags.state.withLock { $0.entered = true }
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            flags.state.withLock { $0.cancelled = true }
        }
        flags.state.withLock { $0.settled = true }
        return .healthy()
    }
}

private func healthStopSettlement() async throws {
    let flags = LifecycleFlags()
    let gate = LifecycleSettlementGate()
    let middleware = HealthCheckMiddleware(configuration: .init(
        checkInterval: 60, healthChecks: ["consumer": SettlementHealthCheck(flags: flags, gate: gate)]
    ))
    do {
        try await observeLifecycle("health check did not enter") { flags.state.withLock { $0.entered } }
    } catch {
        await gate.release()
        await middleware.stopMonitoring()
        throw error
    }
    let stop = Task {
        await middleware.stopMonitoring()
        flags.state.withLock { $0.stopReturned = true }
    }
    do {
        try await observeLifecycle("health stop did not cancel check") { flags.state.withLock { $0.cancelled } }
        let observationEnd = ContinuousClock.now.advanced(by: .milliseconds(100))
        repeat {
            try require(!flags.state.withLock { $0.stopReturned }, "health stop returned before callback settlement")
            await Task.yield()
        } while ContinuousClock.now < observationEnd
        await gate.release()
        await stop.value
        try require(flags.state.withLock { $0.settled && $0.stopReturned }, "health stop failed to join check")
        await middleware.stopMonitoring()
    } catch {
        await gate.release()
        await stop.value
        throw error
    }
}

private func lifecycleMetricEvent(_ name: String) -> PipelineEvent {
    PipelineEvent(
        name: "metric.gauge.recorded",
        properties: ["metric_name": name, "metric_value": 0.5],
        correlationID: "consumer-lifecycle"
    )
}

private func metricsConnectionOwnership() async throws {
    let hub = EventHub()
    let first = MetricsStorage()
    let second = MetricsStorage()
    let firstID = await hub.connectMetrics(first, config: .production)
    let secondID = await hub.connectMetrics(second, config: .production)
    try require(firstID != secondID, "metrics connections share an identifier")
    await hub.emit(lifecycleMetricEvent("consumer.before"))
    await hub.disconnectMetrics(firstID)
    await hub.disconnectMetrics(firstID)
    await hub.emit(lifecycleMetricEvent("consumer.after"))
    try require(await first.getAll().map(\.name) == ["consumer.before"], "disconnected recorder received new event")
    try require(await second.getAll().map(\.name) == ["consumer.before", "consumer.after"], "independent connection lost")
    await hub.disconnectMetrics(secondID)
}

func lifecycle() async throws {
    for owner in LifecycleOwner.allCases {
        let flags = try await exerciseOwner(owner)
        try await observeLifecycle("\(owner.rawValue) retained its resources after owner release") {
            flags.state.withLock { $0.released }
        }
        try emit(["mode": "lifecycle", "owner": owner.rawValue, "phase": "released"])
    }
    await MemoryPressureDetector.shared.stopMonitoring()
    try await healthStopSettlement()
    let responder = MemoryPressureResponder()
    for _ in 0..<2 {
        await responder.startMonitoring()
        async let firstStop: Void = responder.stopMonitoring()
        async let secondStop: Void = responder.stopMonitoring()
        _ = await (firstStop, secondStop)
    }
    try await metricsConnectionOwnership()
    try emit(["mode": "lifecycle", "healthStop": "settled", "memoryRestart": "settled", "metricsDisconnect": "independent"])
}
