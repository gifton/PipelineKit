import Foundation

/// Pipeline with adaptive concurrency control
public actor AdaptivePipeline: Pipeline {
    private let basePipeline: any Pipeline
    private let controller: AdaptiveConcurrencyController
    private var semaphore: BackPressureAsyncSemaphore
    private var monitorTask: Task<Void, Never>?
    
    public init(
        basePipeline: any Pipeline,
        controllerConfig: AdaptiveConcurrencyController.Configuration = .init()
    ) {
        self.basePipeline = basePipeline
        self.controller = AdaptiveConcurrencyController(configuration: controllerConfig)
        
        // Start with initial limit
        let initialLimit = (controllerConfig.minConcurrency + controllerConfig.maxConcurrency) / 2
        self.semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: initialLimit,
            strategy: .suspend
        )
        
        // Start monitoring task
        self.monitorTask = Task {
            await monitorAndAdjust()
        }
    }
    
    deinit {
        monitorTask?.cancel()
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Acquire with current limit
        let token = try await semaphore.acquire()
        defer { _ = token }
        
        do {
            let result = try await basePipeline.execute(command, context: context)
            
            // Record success
            let latency = CFAbsoluteTimeGetCurrent() - startTime
            await controller.recordOperation(latency: latency, success: true)
            
            return result
        } catch {
            // Record failure
            let latency = CFAbsoluteTimeGetCurrent() - startTime
            await controller.recordOperation(latency: latency, success: false)
            
            throw error
        }
    }
    
    private func monitorAndAdjust() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            
            let newLimit = await controller.limit
            let currentLimit = await getCurrentLimit()
            
            if newLimit != currentLimit {
                // Create new semaphore with updated limit
                semaphore = BackPressureAsyncSemaphore(
                    maxConcurrency: newLimit,
                    strategy: .suspend
                )
            }
        }
    }
    
    private func getCurrentLimit() async -> Int {
        await semaphore.getStats().maxConcurrency
    }
    
    /// Get current adaptive metrics
    public func getAdaptiveMetrics() async -> AdaptiveMetrics {
        let currentLimit = await controller.limit
        let stats = await semaphore.getStats()
        
        return AdaptiveMetrics(
            currentConcurrencyLimit: currentLimit,
            activeOperations: stats.activeOperations,
            queuedOperations: stats.queuedOperations,
            utilizationPercent: Double(stats.activeOperations) / Double(currentLimit) * 100
        )
    }
}

/// Metrics for adaptive pipeline monitoring
public struct AdaptiveMetrics: Sendable {
    public let currentConcurrencyLimit: Int
    public let activeOperations: Int
    public let queuedOperations: Int
    public let utilizationPercent: Double
}

/// Extension for creating adaptive pipelines from existing ones
public extension Pipeline {
    /// Wrap this pipeline with adaptive concurrency control
    func withAdaptiveConcurrency(
        configuration: AdaptiveConcurrencyController.Configuration = .init()
    ) -> AdaptivePipeline {
        AdaptivePipeline(basePipeline: self, controllerConfig: configuration)
    }
}