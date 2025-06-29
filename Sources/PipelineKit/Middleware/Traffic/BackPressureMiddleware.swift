import Foundation

/// Middleware that applies back-pressure control to command execution pipelines.
public struct BackPressureMiddleware: Middleware {
    public let priority: ExecutionPriority = .throttling
    private let semaphore: BackPressureAsyncSemaphore
    public let options: PipelineOptions

    public init(options: PipelineOptions) {
        self.options = options
        self.semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: options.maxConcurrency ?? Int.max,
            maxOutstanding: options.maxOutstanding,
            maxQueueMemory: options.maxQueueMemory,
            strategy: options.backPressureStrategy
        )
    }

    public init(
        maxConcurrency: Int,
        maxOutstanding: Int? = nil,
        strategy: BackPressureStrategy = .suspend
    ) {
        let options = PipelineOptions(
            maxConcurrency: maxConcurrency,
            maxOutstanding: maxOutstanding ?? (maxConcurrency * 2),
            backPressureStrategy: strategy
        )
        self.init(options: options)
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let token = try await semaphore.acquire()
        defer { _ = token } 

        return try await next(command, context)
    }
}


extension BackPressureMiddleware {
    public func getStats() async -> BackPressureStats {
        let semaphoreStats = await semaphore.getStats()
        return BackPressureStats(
            maxConcurrency: semaphoreStats.maxConcurrency,
            maxOutstanding: semaphoreStats.maxOutstanding,
            activeOperations: semaphoreStats.activeOperations,
            queuedOperations: semaphoreStats.queuedOperations,
            totalOutstanding: semaphoreStats.totalOutstanding,
            utilizationPercent: Double(semaphoreStats.activeOperations) / Double(semaphoreStats.maxConcurrency) * 100,
            backPressureStrategy: options.backPressureStrategy
        )
    }

    public func isApplyingBackPressure() async -> Bool {
        let stats = await semaphore.getStats()
        return stats.totalOutstanding >= stats.maxOutstanding || stats.availableResources == 0
    }
}

public struct BackPressureStats: Sendable {
    public let maxConcurrency: Int
    public let maxOutstanding: Int?
    public let activeOperations: Int
    public let queuedOperations: Int
    public let totalOutstanding: Int
    public let utilizationPercent: Double
    public let backPressureStrategy: BackPressureStrategy
}

extension BackPressureMiddleware {
    public static func highThroughput() -> BackPressureMiddleware {
        BackPressureMiddleware(options: .highThroughput())
    }

    public static func lowLatency() -> BackPressureMiddleware {
        BackPressureMiddleware(options: .lowLatency())
    }

    public static func flowControl(maxConcurrency: Int) -> BackPressureMiddleware {
        BackPressureMiddleware(
            maxConcurrency: maxConcurrency,
            maxOutstanding: nil,
            strategy: .suspend
        )
    }
}
