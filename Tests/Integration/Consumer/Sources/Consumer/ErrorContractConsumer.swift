import Foundation
import PipelineKit
import PipelineKitResilience

private enum ConsumerServiceError: Error { case unavailable }

private struct ErrorContractCommand: Command {
    typealias Result = String
    enum Outcome: Sendable {
        case success, nativeCancellation, typedCancellation, checkCancellation, validation, unknown, timeout
    }
    let outcome: Outcome
    var gate: SignalGate? = nil
}

private struct ErrorContractHandler: CommandHandler {
    let trace: Trace

    func handle(_ command: ErrorContractCommand, context: CommandContext) async throws -> String {
        trace.add("handler")
        if let gate = command.gate { await gate.pause() }
        switch command.outcome {
        case .success: return "accepted"
        case .nativeCancellation: throw CancellationError()
        case .typedCancellation: throw PipelineError.cancelled(context: "consumer request")
        case .checkCancellation:
            try Task.checkCancellation()
            return "not cancelled"
        case .validation: throw PipelineError.validation(field: "name", reason: .missingRequired)
        case .unknown: throw ConsumerServiceError.unavailable
        case .timeout: throw PipelineError.timeout(duration: 1, context: nil)
        }
    }
}

private func errorContractExecution(
    route: String,
    trace: Trace,
    middlewares: [any Middleware] = []
) async throws -> @Sendable (ErrorContractCommand, CommandContext) async throws -> String {
    let handler = ErrorContractHandler(trace: trace)
    switch route {
    case "standard":
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddlewares(middlewares)
        return { try await pipeline.execute($0, context: $1) }
    case "erased":
        let pipeline = AnyStandardPipeline(handler: handler)
        for middleware in middlewares { try await pipeline.addMiddleware(middleware) }
        return { try await pipeline.execute($0, context: $1) }
    default:
        let pipeline = DynamicPipeline()
        await pipeline.register(ErrorContractCommand.self, handler: handler)
        try await pipeline.addMiddlewares(middlewares)
        return { try await pipeline.send($0, context: $1, retryPolicy: .none) }
    }
}

private func consumerCancellationBoundaries() async throws {
    for route in ["standard", "erased", "dynamic"] {
        let trace = Trace()
        let execute = try await errorContractExecution(route: route, trace: trace)
        let context = CommandContext()
        do {
            _ = try await execute(.init(outcome: .nativeCancellation), context)
            throw ConsumerFailure.expectedFailure
        } catch PipelineError.cancelled {}
        try require(trace.take() == ["handler"], "\(route): native cancellation reached handler once")
        try require(context.getCancellationReason() == .userCancellation, "\(route): cancellation diagnostic")
        try emit(["mode": "error-contract", "route": route, "nativeCancellation": "typed"])
    }
}

private func consumerCancellationPolicies() async throws {
    for route in ["standard", "erased", "dynamic"] {
        let trace = Trace()
        let retry = RetryMiddleware(configuration: .init(
            maxAttempts: 2, strategy: .fixed(delay: 0),
            errorEvaluator: { _ in trace.add("retry predicate"); return true }, emitEvents: false
        ))
        let resilient = ResilientMiddleware(name: "consumer", retryPolicy: .init(
            maxAttempts: 2, delayStrategy: .immediate,
            shouldRetry: { _ in trace.add("resilient predicate"); return true }
        ))
        let breaker = CircuitBreakerMiddleware(configuration: .init(
            failureThreshold: 1, emitEvents: false,
            errorEvaluator: { _ in trace.add("breaker predicate"); return true }
        ))
        let health = HealthCheckMiddleware(configuration: .init(
            failureThreshold: 1, minRequests: 1, emitMetrics: false,
            errorEvaluator: { _ in trace.add("health predicate"); return true }
        ))
        let execute = try await errorContractExecution(
            route: route, trace: trace, middlewares: [retry, resilient, health, breaker]
        )
        for outcome: ErrorContractCommand.Outcome in [.nativeCancellation, .typedCancellation] {
            do {
                _ = try await execute(.init(outcome: outcome), CommandContext())
                throw ConsumerFailure.expectedFailure
            } catch PipelineError.cancelled(let detail) {
                if case .typedCancellation = outcome {
                    try require(detail == "consumer request", "\(route): typed cancellation detail preserved")
                }
            }
            try require(trace.take() == ["handler"], "\(route): cancellation bypasses custom predicates and retries")
        }

        let gate = SignalGate()
        let context = CommandContext()
        let cancelled = Task { try await execute(.init(outcome: .checkCancellation, gate: gate), context) }
        await gate.waitForEntry()
        cancelled.cancel()
        await gate.release()
        do {
            _ = try await cancelled.value
            throw ConsumerFailure.expectedFailure
        } catch PipelineError.cancelled {}
        try require(trace.take() == ["handler"], "\(route): cancelled task entered once without custom evaluation")
        try require(context.getCancellationReason() == .userCancellation, "\(route): task cancellation diagnostic")
        let status = await health.getHealthStatus(for: "ErrorContractCommand")
        try require(status.totalRequests == 0 && status.recentFailures == 0, "\(route): cancellation excluded from health window")
        try require(try await execute(.init(outcome: .success), CommandContext()) == "accepted", "\(route): breaker admits execution after cancellation")
        try require(trace.take() == ["handler"], "\(route): next live request entered once")
        try emit(["mode": "error-contract", "route": route, "cancellations": 3,
                  "customPredicateCalls": 0, "scoredFailures": 0, "liveRequestAfterCancellation": "accepted"])
    }
}

private func consumerDefaultFailurePolicies() async throws {
    for outcome: ErrorContractCommand.Outcome in [.unknown, .timeout] {
        let trace = Trace()
        let health = HealthCheckMiddleware(configuration: .init(failureThreshold: 1, minRequests: 1, emitMetrics: false))
        let breaker = CircuitBreakerMiddleware(configuration: .init(failureThreshold: 1, recoveryTimeout: 60, emitEvents: false))
        let execute = try await errorContractExecution(route: "standard", trace: trace, middlewares: [health, breaker])
        do {
            _ = try await execute(.init(outcome: .validation), CommandContext())
            throw ConsumerFailure.expectedFailure
        } catch PipelineError.validation(let field, .missingRequired) {
            try require(field == "name", "validation error identity")
        }
        let ignored = await health.getHealthStatus(for: "ErrorContractCommand")
        try require(ignored.totalRequests == 0 && ignored.recentFailures == 0, "validation excluded from health window")
        try require(trace.take() == ["handler"], "validation reached handler once")
        do {
            _ = try await execute(.init(outcome: outcome), CommandContext())
            throw ConsumerFailure.expectedFailure
        } catch ConsumerServiceError.unavailable {
            guard case .unknown = outcome else { throw ConsumerFailure.assertion("timeout identity changed") }
        } catch PipelineError.timeout {
            guard case .timeout = outcome else { throw ConsumerFailure.assertion("unknown error identity changed") }
        }
        try require(trace.take() == ["handler"], "default breaker admits subsequent handler after validation")
        let failed = await health.getHealthStatus(for: "ErrorContractCommand")
        try require(failed.totalRequests == 1 && failed.recentFailures == 1 && failed.state == .unhealthy,
                    "unknown errors and timeouts score one health failure")
        do {
            _ = try await execute(.init(outcome: .success), CommandContext())
            throw ConsumerFailure.expectedFailure
        } catch PipelineError.circuitBreakerOpen(let resetTime) {
            try require(resetTime != nil, "open breaker supplies its reset deadline")
        }
        let rejected = await health.getHealthStatus(for: "ErrorContractCommand")
        try require(rejected.totalRequests == 1 && rejected.recentFailures == 1, "breaker rejection excluded from health window")
        try require(trace.take().isEmpty, "open breaker rejects before handler")
        try emit(["mode": "error-contract", "defaultScoring": String(describing: outcome),
                  "validationRequests": 0, "serviceFailures": 1, "breakerRejection": "typed"])
    }
}

private func consumerBulkheadErrors() async throws {
    let rejection = PipelineError.bulkheadRejected(reason: "consumer fixture")
    let timeout = PipelineError.bulkheadTimeout(timeout: 1, queueTime: 2)
    guard case .bulkheadRejected(let reason) = rejection, reason == "consumer fixture",
          case .bulkheadTimeout(let duration, let queueTime) = timeout,
          duration > 0, queueTime > duration else {
        throw ConsumerFailure.assertion("public bulkhead constructors must produce typed cases")
    }
    let bulkhead = BulkheadMiddleware(configuration: .init(maxConcurrency: 1, maxQueueSize: 0, emitMetrics: false))
    let health = HealthCheckMiddleware(configuration: .init(failureThreshold: 1, minRequests: 1, emitMetrics: false))
    let gate = SignalGate()
    let trace = Trace()
    let holder = Task {
        try await bulkhead.execute(PlainCommand(), context: CommandContext()) { _, _ in
            trace.add("holder")
            await gate.pause()
            return "settled"
        }
    }
    await gate.waitForEntry()
    var produced: (any Error)?
    do {
        _ = try await health.execute(PlainCommand(), context: CommandContext()) { command, context in
            try await bulkhead.execute(command, context: context) { _, _ in
                trace.add("rejected handler")
                return "unexpected"
            }
        }
    } catch { produced = error }
    await gate.release()
    try require(try await holder.value == "settled", "bulkhead holder joined")
    guard let produced, case PipelineError.bulkheadRejected = produced else {
        throw ConsumerFailure.assertion("actual bulkhead rejection must be typed")
    }
    let status = await health.getHealthStatus(for: "PlainCommand")
    try require(status.totalRequests == 0 && status.recentFailures == 0, "bulkhead rejection excluded from health window")
    try require(trace.take() == ["holder"], "bulkhead rejected before handler")
    let result = try await bulkhead.execute(PlainCommand(), context: CommandContext()) { _, _ in "accepted" }
    try require(result == "accepted", "bulkhead permit reusable after holder settles")
    try emit(["mode": "error-contract", "bulkheadConstructors": "typed", "bulkheadRejection": "typed",
              "rejectedHandlerEntries": 0, "healthFailures": 0, "permitAfterJoin": "reused"])
}

func errorContract() async throws {
    try await consumerCancellationBoundaries()
    try await consumerCancellationPolicies()
    try await consumerDefaultFailurePolicies()
    try await consumerBulkheadErrors()
}
