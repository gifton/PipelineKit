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

    func submit(_ command: SubmitOrderCommand) throws -> String {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
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
        next: @Sendable (T, CommandContext) async throws -> T.Result
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
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = ContinuousClock.now
        defer { print("[timing] \(type(of: command)) took \(ContinuousClock.now - start)") }
        return try await next(command, context)
    }
}

// MARK: - Wire the stack

let pipeline = StandardPipeline(handler: SubmitOrderHandler(service: FlakyOrderService()))
try await pipeline.addMiddleware(OrderValidationMiddleware())
try await pipeline.addMiddleware(TimingMiddleware())
try await pipeline.addMiddleware(
    RetryMiddleware(
        configuration: .init(
            maxAttempts: 3,
            strategy: .exponentialJitter(baseDelay: 0.05, maxDelay: 0.5),
            errorEvaluator: { $0 is TransientOutage }
        )
    )
)

// Happy path: fails twice inside the handler, retried to success.
let confirmation = try await pipeline.execute(SubmitOrderCommand(productID: "sku-42", quantity: 3))
print("confirmed: \(confirmation)")

// Failure path: validation rejects the command before the handler runs.
do {
    _ = try await pipeline.execute(SubmitOrderCommand(productID: "sku-42", quantity: 0))
    print("ERROR: validation should have rejected quantity 0")
} catch is InvalidQuantity {
    print("rejected as expected: quantity must be positive")
}
