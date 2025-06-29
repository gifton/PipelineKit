import Foundation

/// Middleware that enforces time limits on command execution
public final class TimeoutMiddleware: Middleware {
    public let priority: ExecutionPriority = .errorHandling
    private let timeout: TimeInterval
    private let timeoutBudgetKey: TimeoutBudgetKey?
    
    public init(
        timeout: TimeInterval,
        cascading: Bool = false
    ) {
        self.timeout = timeout
        self.timeoutBudgetKey = cascading ? TimeoutBudgetKey() : nil
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let effectiveTimeout: TimeInterval
        
        if timeoutBudgetKey != nil,
           let budget = await context[TimeoutBudgetKey.self] {
            effectiveTimeout = budget.remaining
            guard effectiveTimeout > 0 else {
                throw ResilienceError.timeout(seconds: 0)
            }
        } else {
            effectiveTimeout = timeout
        }
        
        let startTime = Date()
        
        do {
            return try await withThrowingTaskGroup(of: T.Result.self) { group in
                group.addTask {
                    try await next(command, context)
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                    throw ResilienceError.timeout(seconds: effectiveTimeout)
                }
                
                let result = try await group.next()!
                group.cancelAll()
                
                // Update timeout budget if cascading
                if timeoutBudgetKey != nil {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if let budget = await context[TimeoutBudgetKey.self] {
                        let newBudget = budget.consume(elapsed)
                        await context.set(newBudget, for: TimeoutBudgetKey.self)
                    }
                }
                
                return result
            }
        } catch {
            throw error
        }
    }
}

private struct TimeoutBudgetKey: ContextKey {
    typealias Value = TimeoutBudget
}