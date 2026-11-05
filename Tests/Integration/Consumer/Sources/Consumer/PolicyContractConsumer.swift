import Foundation
import Synchronization
import PipelineKit
import PipelineKitResilience

private struct PolicyCommand: Command { typealias Result = Int }
private struct PolicyHandler: CommandHandler {
    func handle(_ command: PolicyCommand, context: CommandContext) async throws -> Int { 7 }
}
private final class PolicyFailure: Error, Sendable {}
private struct PolicyHTTPFailure: Error { let status: Int }

private final class PolicyCounter: Sendable {
    private let count = Mutex(0)
    func increment() -> Int { count.withLock { $0 += 1; return $0 } }
    var value: Int { count.withLock { $0 } }
}

private enum PolicyFetchOutcome: Sendable, Equatable {
    case recovers, exhausts, permanentFailure, cancellation
}

private struct PolicyFetchHandler: CommandHandler {
    let outcome: PolicyFetchOutcome
    let attempts: PolicyCounter

    func handle(_ command: FetchDataCommand, context: CommandContext) async throws -> Data {
        let attempt = attempts.increment()
        switch outcome {
        case .recovers:
            if attempt == 1 { throw URLError(.timedOut) }
            return Data("tutorial-result".utf8)
        case .exhausts:
            throw URLError(.timedOut)
        case .permanentFailure:
            throw URLError(.badURL)
        case .cancellation:
            throw CancellationError()
        }
    }
}

private struct PolicyGuardedAttempts: Middleware {
    let priority: ExecutionPriority = .postProcessing
    let traversals: PolicyCounter

    func execute<C: Command>(
        _ command: C,
        context: CommandContext,
        next: @Sendable (C, CommandContext) async throws -> C.Result
    ) async throws -> C.Result {
        _ = traversals.increment()
        return try await next(command, context)
    }
}

private final class PolicyGate: Sendable {
    private struct State {
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resume = state.withLock { state in
                    if state.released { return true }
                    state.continuation = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        } onCancel: {
            release()
        }
    }
    func release() {
        let continuation = state.withLock { state in
            state.released = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private struct PolicyGraceEmitter: EventEmitter {
    let gate: PolicyGate
    func emit(_ event: PipelineEvent) async {
        if event.name == "middleware.timeout_grace_period" { gate.release() }
    }
}

private actor PolicyMetrics: MetricsCollector {
    private var counters: [String: Double] = [:]
    private var timers: [String: Int] = [:]
    func recordCounter(_ name: String, value: Double, tags: [String: String]) {
        counters[name, default: 0] += value
    }
    func recordGauge(_ name: String, value: Double, tags: [String: String]) {}
    func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) {
        timers[name, default: 0] += 1
    }
    func recordHistogram(_ name: String, value: Double, tags: [String: String]) {}
    func counter(_ name: String) -> Double { counters[name, default: 0] }
    func timerCount(_ name: String) -> Int { timers[name, default: 0] }
}

// Deliberately supplies only the original capability, even though the delegated
// in-memory implementation also supports reset-all. This is an external adapter.
private actor PolicyBasicStore: DistributedRateLimitStore {
    private let storage = InMemoryRateLimitStore()
    let resetFailure: PolicyFailure?
    init(resetFailure: PolicyFailure? = nil) { self.resetFailure = resetFailure }
    func incrementAndGet(key: String, windowSize: TimeInterval) async throws -> Int {
        try await storage.incrementAndGet(key: key, windowSize: windowSize)
    }
    func getCount(key: String, windowSize: TimeInterval) async throws -> Int {
        try await storage.getCount(key: key, windowSize: windowSize)
    }
    func reset(key: String) async throws {
        if let resetFailure { throw resetFailure }
        try await storage.reset(key: key)
    }
}

private func policyRetry() async throws {
    let failure = PolicyFailure()
    let attempts = PolicyCounter()
    let retry = RetryMiddleware(configuration: .init(
        maxAttempts: 2,
        strategy: .fixed(delay: 30),
        errorEvaluator: { _ in true },
        emitEvents: false,
        maxRetryTime: 0.02
    ))
    let start = ContinuousClock.now
    do {
        _ = try await retry.execute(PolicyCommand(), context: CommandContext()) { _, _ in
            _ = attempts.increment()
            throw failure
        }
        throw ConsumerFailure.assertion("retry unexpectedly succeeded")
    } catch {
        try require((error as? PolicyFailure) === failure, "retry budget replaced original failure")
    }
    try require(attempts.value == 1, "expired retry budget admitted another attempt")
    try require(start.duration(to: ContinuousClock.now) < .seconds(5), "retry slept the full backoff beyond its budget")

    let httpAttempts = PolicyCounter()
    let extracted = PolicyCounter()
    let http = RetryMiddleware.forHTTPStatusCodes([503]) { error in
        _ = extracted.increment()
        return (error as? PolicyHTTPFailure)?.status
    }
    let value = try await http.execute(PolicyCommand(), context: CommandContext()) { _, _ in
        if httpAttempts.increment() == 1 { throw PolicyHTTPFailure(status: 503) }
        return 7
    }
    try require(value == 7 && httpAttempts.value == 2 && extracted.value == 1, "HTTP extraction did not govern retry")
    do {
        _ = try await http.execute(PolicyCommand(), context: CommandContext()) { _, _ in
            throw CancellationError()
        }
        throw ConsumerFailure.assertion("cancelled HTTP call succeeded")
    } catch PipelineError.cancelled {}
    try require(extracted.value == 1, "cancellation reached HTTP extractor")
}

private func policyTutorialRetry() async throws {
    guard let fixtureURL = URL(string: "https://example.invalid/qualification") else {
        throw ConsumerFailure.assertion("tutorial retry fixture URL could not be constructed")
    }
    let scenarios: [(PolicyFetchOutcome, Int)] = [
        (.recovers, 2), (.exhausts, 3), (.permanentFailure, 1), (.cancellation, 1)
    ]
    for route in ["standard", "builder", "dynamic"] {
        for (outcome, expectedAttempts) in scenarios {
            let attempts = PolicyCounter()
            let traversals = PolicyCounter()
            let handler = PolicyFetchHandler(outcome: outcome, attempts: attempts)
            // This factory is extracted verbatim from basic-usage.md.
            let retry = makeFetchDataRetryMiddleware()
            let guarded = PolicyGuardedAttempts(traversals: traversals)
            let execute: @Sendable (FetchDataCommand, CommandContext) async throws -> Data
            switch route {
            case "standard":
                let pipeline = StandardPipeline(handler: handler)
                try await pipeline.addMiddleware(retry)
                try await pipeline.addMiddleware(guarded)
                execute = { try await pipeline.execute($0, context: $1) }
            case "builder":
                let builder = PipelineBuilder(handler: handler)
                await builder.addMiddleware(retry)
                await builder.addMiddleware(guarded)
                let pipeline = try await builder.build()
                execute = { try await pipeline.execute($0, context: $1) }
            default:
                let pipeline = DynamicPipeline()
                await pipeline.register(FetchDataCommand.self, handler: handler)
                try await pipeline.addMiddleware(retry)
                try await pipeline.addMiddleware(guarded)
                // The middleware owns retries; disable the pipeline's outer retry policy.
                execute = { try await pipeline.send($0, context: $1, retryPolicy: .none) }
            }

            do {
                let result = try await execute(
                    FetchDataCommand(url: fixtureURL),
                    CommandContext()
                )
                try require(outcome == .recovers, "\(route): failing tutorial operation succeeded")
                try require(result == Data("tutorial-result".utf8), "\(route): retry changed handler output")
            } catch let error as URLError {
                let expectedCode: URLError.Code
                switch outcome {
                case .exhausts: expectedCode = .timedOut
                case .permanentFailure: expectedCode = .badURL
                default: throw ConsumerFailure.assertion("\(route): unexpected transport failure: \(error)")
                }
                try require(error.code == expectedCode, "\(route): retry replaced transport failure")
            } catch PipelineError.cancelled {
                try require(outcome == .cancellation, "\(route): unexpected tutorial cancellation")
            }
            try require(attempts.value == expectedAttempts, "\(route): tutorial retry attempt count differs")
            try require(traversals.value == expectedAttempts, "\(route): retry did not traverse guarded middleware per attempt")
        }
    }
}

private func policyTimeout() async throws {
    let metrics = PolicyMetrics()
    let timeout = TimeoutMiddleware(configuration: .init(
        defaultTimeout: 0.01, gracePeriod: 1, metricsCollector: metrics
    ))
    for _ in 0..<2 {
        let gate = PolicyGate()
        let context = CommandContext()
        context.eventEmitter = PolicyGraceEmitter(gate: gate)
        let result = try await timeout.execute(PolicyCommand(), context: context) { _, _ in
            await gate.wait()
            return 7
        }
        try require(result == 7, "grace recovery lost handler result")
    }
    let recoveries = await metrics.counter("pipeline.timeout.grace_recovery")
    try require(abs(recoveries - 2) < 0.000_001, "reused timeout middleware lost grace recovery metrics")
    try require(await metrics.timerCount("pipeline.timeout.grace_duration") == 2, "grace timer count differs")
    let nearTimeouts = await metrics.counter("pipeline.timeout.near_timeout")
    try require(abs(nearTimeouts) < 0.000_001, "grace recovery was misclassified as near-timeout")

    let nestedContext = CommandContext()
    do {
        _ = try await timeout.execute(PolicyCommand(), context: nestedContext) { _, _ in
            try await withTimeout(-17.25) { 7 }
        }
        throw ConsumerFailure.assertion("nested timeout unexpectedly succeeded")
    } catch TimeoutError.exceeded(let duration) {
        try require(abs(duration + 17.25) < 0.000_001, "outer middleware replaced nested timeout payload")
    }
    try require(nestedContext.getCancellationReason() == nil, "nested timeout marked an outer deadline")
    let outerTimeouts = await metrics.counter("pipeline.timeout.exceeded")
    try require(abs(outerTimeouts) < 0.000_001, "nested timeout recorded an outer deadline")
}

private func policyRateLimits() async throws {
    let limiter = RateLimiter(strategy: .priorityBased(limits: [
        .medium: .init(maxRequests: 0, windowSize: 60),
        .high: .init(maxRequests: 1, windowSize: 60)
    ]))
    let middleware = EnhancedRateLimitingMiddleware(
        limiter: limiter, identifierExtractor: { _, _ in "customer" }, priorityExtractor: { _, _ in .high }
    )
    let result = try await middleware.execute(PolicyCommand(), context: CommandContext()) { _, _ in 7 }
    try require(result == 7, "extracted priority was not applied")
    try require(try await limiter.getStatus(identifier: "customer", priority: .high).remaining == 0, "priority status differs")
    try await limiter.reset(identifier: "customer", priority: .high)
    try require(try await limiter.allowRequest(identifier: "customer", priority: .high), "keyed priority reset failed")
    try await limiter.reset()
    try require(try await limiter.getStatus(identifier: "customer", priority: .high).remaining == 1, "reset-all missed priority")

    let store = InMemoryRateLimitStore()
    let first = RateLimiter(strategy: .distributed(store: store, windowSize: 60, maxRequests: 1), scope: .perUser)
    let second = RateLimiter(strategy: .distributed(store: store, windowSize: 60, maxRequests: 1), scope: .perUser)
    let otherScope = RateLimiter(strategy: .distributed(store: store, windowSize: 60, maxRequests: 1), scope: .perCommand)
    _ = try await first.allowRequest(identifier: "remote-only")
    _ = try await otherScope.allowRequest(identifier: "remote-only")
    try await second.reset()
    try require(try await first.allowRequest(identifier: "remote-only"), "distributed reset-all missed remote key")
    try require(try await !otherScope.allowRequest(identifier: "remote-only"), "distributed reset crossed scope namespace")
    try await second.reset(identifier: "remote-only")
    try require(try await first.allowRequest(identifier: "remote-only"), "distributed keyed reset was not shared")

    let basic = RateLimiter(strategy: .distributed(store: PolicyBasicStore(), windowSize: 60, maxRequests: 1))
    do {
        try await basic.reset()
        throw ConsumerFailure.assertion("unsupported distributed reset-all claimed success")
    } catch RateLimitResetError.resetAllUnsupported {}
    let failure = PolicyFailure()
    let failing = RateLimiter(strategy: .distributed(store: PolicyBasicStore(resetFailure: failure), windowSize: 60, maxRequests: 1))
    do {
        try await failing.reset(identifier: "customer")
        throw ConsumerFailure.assertion("failed distributed reset claimed success")
    } catch {
        try require((error as? PolicyFailure) === failure, "reset replaced store error")
    }
}

private func policyOutstandingLimits() async throws {
    let strategies: [BackPressureStrategy] = [.suspend, .error(timeout: nil), .error(timeout: 60), .dropNewest, .dropOldest]
    for strategy in strategies {
        let semaphore = BackPressureSemaphore(maxConcurrency: 2, maxOutstanding: 1, strategy: strategy)
        let held = try await semaphore.acquire()
        defer { held.release() }
        do {
            let extra = try await semaphore.acquire(timeout: 0.01)
            extra?.release()
            throw ConsumerFailure.assertion("outstanding cap admitted an extra operation")
        } catch PipelineError.backPressure(let reason) {
            switch (strategy, reason) {
            case (.dropNewest, .commandDropped): break
            case (_, .queueFull):
                try require(strategy != .dropNewest, "drop-newest returned wrong rejection")
            default: throw ConsumerFailure.assertion("outstanding cap returned wrong rejection: \(reason)")
            }
        }
        let stats = await semaphore.getStats()
        try require(stats.activeOperations == 1 && stats.queuedOperations == 0 && stats.totalOutstanding == 1,
                    "rejected admission altered capacity ownership")
        held.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await semaphore.getStats().activeOperations != 0 {
            try require(ContinuousClock.now < deadline, "released capacity did not settle")
            await Task.yield()
        }
    }
}

func policyContract() async throws {
    try await policyRetry()
    try await policyTutorialRetry()
    try await policyTimeout()
    try await policyRateLimits()
    try await policyOutstandingLimits()
    try await policySettledCapacity()
    try emit([
        "mode": "policy-contract",
        "retry": "bounded",
        "tutorialRetry": "guarded-chain-matrix",
        "grace": "per-invocation",
        "priorityAndReset": "effective",
        "outstanding": "strict"
    ])
}

private func policySettledCapacity() async throws {
    let strategies: [BackPressureStrategy] = [.suspend, .error(timeout: nil), .error(timeout: 60), .dropNewest, .dropOldest]
    for strategy in strategies {
        let middleware = BackPressureMiddleware(maxConcurrency: 1, maxOutstanding: 1, strategy: strategy)
        let pipeline = ConcurrentPipeline(options: .init(
            maxConcurrency: 1, maxOutstanding: 1, backPressureStrategy: strategy
        ))
        await pipeline.register(PolicyCommand.self, pipeline: StandardPipeline(handler: PolicyHandler()))
        for route in 0..<4 {
            for _ in 0..<2 {
                let value: Int
                switch route {
                case 0:
                    value = try await middleware.execute(PolicyCommand(), context: CommandContext()) { _, _ in 7 }
                case 1:
                    value = try await middleware.execute(PolicyCommand(), context: CommandContext(), estimatedSize: 1) { _, _ in 7 }
                case 2:
                    value = try await pipeline.execute(PolicyCommand())
                default:
                    value = try await pipeline.execute(PolicyCommand(), timeout: 60)
                }
                try require(value == 7, "sequential capacity-one execution lost its result")
            }
        }
        try require(await middleware.getStats().activeOperations == 0, "settled middleware retained capacity")
        try require(await pipeline.getCapacityStats().totalOutstanding == 0, "settled pipeline retained capacity")
    }
}
