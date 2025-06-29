import Foundation

/// Example metrics middleware using context.
public struct MetricsMiddleware: Middleware {
    public let priority: ExecutionPriority = .metrics
    private let recordMetric: @Sendable (String, TimeInterval) async -> Void

    public init(recordMetric: @escaping @Sendable (String, TimeInterval) async -> Void) {
        self.recordMetric = recordMetric
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = await context[RequestStartTimeKey.self] ?? Date()

        do {
            let result = try await next(command, context)

            let duration = Date().timeIntervalSince(startTime)
            await recordMetric(String(describing: T.self), duration)

            return result
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            await recordMetric("\(String(describing: T.self)).error", duration)
            throw error
        }
    }
}
