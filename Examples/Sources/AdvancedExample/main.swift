import PipelineKit
import PipelineKitResilience

// A middleware stack on one pipeline: validation rejects bad input before the
// handler runs, RetryMiddleware recovers from transient failures, and a timing
// middleware measures each execution.

// MARK: - Domain

struct SubmitOrderCommand: Command {
    typealias Result = String
    let productID: String
    let quantity: Int
}

struct InvalidQuantity: Error {}
struct TransientOutage: Error {}

// A handler that fails twice before succeeding, so RetryMiddleware has
// something visible to recover from.
actor FlakyOrderService {
    private var failuresRemaining = 2
    private(set) var attempts = 0
    private(set) var transientFailures = 0

    func submit(_ command: SubmitOrderCommand) throws -> String {
        attempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            transientFailures += 1
            throw TransientOutage()
        }
        return "order-\(command.productID)-x\(command.quantity)"
    }
}

struct SubmitOrderHandler: CommandHandler {
    typealias CommandType = SubmitOrderCommand
    let service: FlakyOrderService

    func handle(_ command: SubmitOrderCommand, context: CommandContext) async throws -> String {
        try await service.submit(command)
    }
}

// MARK: - Custom middleware

struct OrderValidationMiddleware: Middleware {
    let priority = ExecutionPriority.validation

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        if let order = command as? SubmitOrderCommand, order.quantity <= 0 {
            throw InvalidQuantity()
        }
        return try await next(command, context)
    }
}

struct TimingMiddleware: Middleware {
    let priority = ExecutionPriority.monitoring

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let start = ContinuousClock.now
        defer { print("[timing] \(type(of: command)) took \(ContinuousClock.now - start)") }
        return try await next(command, context)
    }
}

// MARK: - Wire the stack

let service = FlakyOrderService()
let pipeline = StandardPipeline(handler: SubmitOrderHandler(service: service))
try await pipeline.addMiddleware(OrderValidationMiddleware())
try await pipeline.addMiddleware(TimingMiddleware())
try await pipeline.addMiddleware(
    RetryMiddleware(
        configuration: .init(
            maxAttempts: 2,
            strategy: .fixed(delay: 0.001),
            errorEvaluator: { $0 is TransientOutage }
        )
    )
)

// Happy path: fails twice inside the handler, retried to success.
let confirmation = try await pipeline.execute(SubmitOrderCommand(productID: "sku-42", quantity: 3))
guard confirmation == "order-sku-42-x3" else { throw ExampleFailure.unexpectedConfirmation }
guard await service.attempts == 3, await service.transientFailures == 2 else {
    throw ExampleFailure.unexpectedRetryCounts
}
print("confirmed: \(confirmation)")

// Failure path: validation rejects the command before the handler runs.
do {
    _ = try await pipeline.execute(SubmitOrderCommand(productID: "sku-42", quantity: 0))
    throw ExampleFailure.validationNotRejected
} catch is InvalidQuantity {
    print("rejected as expected: quantity must be positive")
}
guard await service.attempts == 3 else { throw ExampleFailure.invalidOrderReachedHandler }
print("PASS: AdvancedExample")

enum ExampleFailure: Error {
    case unexpectedConfirmation, unexpectedRetryCounts, validationNotRejected, invalidOrderReachedHandler
}
