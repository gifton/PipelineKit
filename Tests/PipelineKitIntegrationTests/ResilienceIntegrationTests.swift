import XCTest
@testable import PipelineKit

/// Integration tests for resilience and recovery scenarios
final class ResilienceIntegrationTests: XCTestCase {
    
    // MARK: - Cascading Failure Recovery Test
    
    func testCascadingFailureRecovery() async throws {
        // Given - System with dependencies that can fail
        let dependencyA = FailingService(name: "ServiceA", failureRate: 0.3)
        let dependencyB = FailingService(name: "ServiceB", failureRate: 0.2)
        let dependencyC = FailingService(name: "ServiceC", failureRate: 0.1)
        
        let pipeline = StandardPipeline()
        
        // Add circuit breakers for each dependency
        let circuitBreakerA = CircuitBreaker(failureThreshold: 3, timeout: 0.5)
        let circuitBreakerB = CircuitBreaker(failureThreshold: 3, timeout: 0.5)
        let circuitBreakerC = CircuitBreaker(failureThreshold: 3, timeout: 0.5)
        
        // Configure pipeline with resilience patterns
        pipeline.use(HealthCheckMiddleware(services: [dependencyA, dependencyB, dependencyC]))
        pipeline.use(CircuitBreakerMiddleware(breaker: circuitBreakerA, serviceId: "ServiceA"))
        pipeline.use(CircuitBreakerMiddleware(breaker: circuitBreakerB, serviceId: "ServiceB"))
        pipeline.use(CircuitBreakerMiddleware(breaker: circuitBreakerC, serviceId: "ServiceC"))
        pipeline.use(FallbackMiddleware(fallbackProvider: SmartFallbackProvider()))
        pipeline.use(BulkheadMiddleware(maxConcurrency: 10))
        
        pipeline.registerHandler { (command: ComplexOperationCommand, context: Context) in
            // Try to use all services
            let resultA = try? await dependencyA.execute()
            let resultB = try? await dependencyB.execute()
            let resultC = try? await dependencyC.execute()
            
            // Use fallbacks if needed
            let finalResultA = resultA ?? (context.metadata["fallback_A"] as? String ?? "default_A")
            let finalResultB = resultB ?? (context.metadata["fallback_B"] as? String ?? "default_B")
            let finalResultC = resultC ?? (context.metadata["fallback_C"] as? String ?? "default_C")
            
            return ComplexOperationResult(
                resultA: finalResultA,
                resultB: finalResultB,
                resultC: finalResultC,
                degraded: resultA == nil || resultB == nil || resultC == nil
            )
        }
        
        // When - Execute many operations to trigger failures
        var results: [ComplexOperationResult] = []
        var degradedCount = 0
        
        for i in 0..<50 {
            let context = CommandContext.test()
            let command = ComplexOperationCommand(id: "op-\(i)")
            
            do {
                let result = try await pipeline.execute(command, context: context)
                results.append(result)
                if result.degraded {
                    degradedCount += 1
                }
            } catch {
                // Count complete failures
                print("Operation \(i) failed completely: \(error)")
            }
        }
        
        // Then - System should handle failures gracefully
        XCTAssertGreaterThan(results.count, 30, "Most operations should complete")
        XCTAssertGreaterThan(degradedCount, 0, "Some operations should be degraded")
        
        // Verify circuit breakers opened for failing services
        let circuitStates = [
            await circuitBreakerA.getState(),
            await circuitBreakerB.getState(),
            await circuitBreakerC.getState()
        ]
        
        let openCircuits = circuitStates.filter { if case .open = $0 { return true } else { return false } }.count
        XCTAssertGreaterThan(openCircuits, 0, "At least one circuit should open")
    }
    
    // MARK: - Graceful Degradation Test
    
    func testGracefulDegradation() async throws {
        // Given - System with optional features
        let pipeline = StandardPipeline()
        let featureFlags = FeatureFlags()
        
        pipeline.use(FeatureFlagMiddleware(flags: featureFlags))
        pipeline.use(GracefulDegradationMiddleware())
        pipeline.use(CachingMiddleware(cache: InMemoryCache()))
        pipeline.use(MetricsMiddleware())
        
        pipeline.registerHandler { (command: FeatureRichCommand, context: Context) in
            var enabledFeatures: [String] = []
            
            // Check which features are available
            if context.metadata["feature_recommendations"] as? Bool ?? false {
                enabledFeatures.append("recommendations")
            }
            
            if context.metadata["feature_analytics"] as? Bool ?? false {
                enabledFeatures.append("analytics")
            }
            
            if context.metadata["feature_personalization"] as? Bool ?? false {
                enabledFeatures.append("personalization")
            }
            
            // Core functionality always available
            enabledFeatures.append("core")
            
            return FeatureRichResult(
                data: "Core data",
                enabledFeatures: enabledFeatures,
                performanceMode: context.metadata["performance_mode"] as? String ?? "normal"
            )
        }
        
        // When - Simulate various load conditions
        
        // Normal load
        featureFlags.setAll(enabled: true)
        let normalResult = try await pipeline.execute(
            FeatureRichCommand(),
            context: CommandContext.test()
        )
        
        // High load - disable some features
        featureFlags.disable(["recommendations", "personalization"])
        let highLoadResult = try await pipeline.execute(
            FeatureRichCommand(),
            context: CommandContext.test()
        )
        
        // Critical load - minimal features
        featureFlags.setAll(enabled: false)
        let criticalResult = try await pipeline.execute(
            FeatureRichCommand(),
            context: CommandContext.test()
        )
        
        // Then - Verify graceful degradation
        XCTAssertEqual(normalResult.enabledFeatures.count, 4, "All features enabled under normal load")
        XCTAssertEqual(highLoadResult.enabledFeatures.count, 2, "Some features disabled under high load")
        XCTAssertEqual(criticalResult.enabledFeatures.count, 1, "Only core features under critical load")
        
        // All requests should complete successfully
        XCTAssertEqual(normalResult.data, "Core data")
        XCTAssertEqual(highLoadResult.data, "Core data")
        XCTAssertEqual(criticalResult.data, "Core data")
    }
    
    // MARK: - Distributed Transaction Recovery Test
    
    func testDistributedTransactionRecovery() async throws {
        // Given - Saga pattern implementation
        let pipeline = StandardPipeline()
        let sagaCoordinator = SagaCoordinator()
        
        pipeline.use(SagaMiddleware(coordinator: sagaCoordinator))
        pipeline.use(CompensationMiddleware())
        pipeline.use(IdempotencyMiddleware())
        pipeline.use(EventSourcingMiddleware())
        
        // Define saga steps
        let orderSaga = Saga(
            name: "OrderProcessing",
            steps: [
                SagaStep(
                    name: "ReserveInventory",
                    forward: { context in
                        // May fail
                        if Bool.random() && Bool.random() {
                            throw SagaError.stepFailed("Inventory unavailable")
                        }
                        context.metadata["inventory_reserved"] = true
                    },
                    compensate: { context in
                        context.metadata["inventory_reserved"] = false
                        print("Compensated: Released inventory")
                    }
                ),
                SagaStep(
                    name: "ChargePayment",
                    forward: { context in
                        guard context.metadata["inventory_reserved"] as? Bool == true else {
                            throw SagaError.preconditionFailed
                        }
                        // May fail
                        if Bool.random() && Bool.random() && Bool.random() {
                            throw SagaError.stepFailed("Payment declined")
                        }
                        context.metadata["payment_charged"] = true
                    },
                    compensate: { context in
                        context.metadata["payment_charged"] = false
                        print("Compensated: Refunded payment")
                    }
                ),
                SagaStep(
                    name: "CreateShipment",
                    forward: { context in
                        guard context.metadata["payment_charged"] as? Bool == true else {
                            throw SagaError.preconditionFailed
                        }
                        context.metadata["shipment_created"] = true
                    },
                    compensate: { context in
                        context.metadata["shipment_created"] = false
                        print("Compensated: Cancelled shipment")
                    }
                )
            ]
        )
        
        sagaCoordinator.register(saga: orderSaga)
        
        pipeline.registerHandler { (command: OrderSagaCommand, context: Context) in
            let sagaResult = try await sagaCoordinator.execute(
                sagaName: "OrderProcessing",
                context: context
            )
            
            return OrderSagaResult(
                success: sagaResult.success,
                completedSteps: sagaResult.completedSteps,
                compensatedSteps: sagaResult.compensatedSteps
            )
        }
        
        // When - Execute multiple transactions
        var successCount = 0
        var compensationCount = 0
        
        for i in 0..<20 {
            let context = CommandContext.test()
            context.metadata["order_id"] = "order-\(i)"
            
            let result = try await pipeline.execute(
                OrderSagaCommand(orderId: "order-\(i)"),
                context: context
            )
            
            if result.success {
                successCount += 1
            } else {
                compensationCount += 1
            }
            
            print("Order \(i): Success=\(result.success), Completed=\(result.completedSteps), Compensated=\(result.compensatedSteps)")
        }
        
        // Then - Verify saga behavior
        XCTAssertGreaterThan(successCount, 0, "Some transactions should succeed")
        XCTAssertGreaterThan(compensationCount, 0, "Some transactions should fail and compensate")
        
        // Verify no partial states (all or nothing)
        let finalStates = sagaCoordinator.getAllTransactionStates()
        for state in finalStates {
            if !state.success {
                // Failed transactions should have compensated all completed steps
                XCTAssertEqual(
                    state.completedSteps.count,
                    state.compensatedSteps.count,
                    "All completed steps should be compensated on failure"
                )
            }
        }
    }
    
    // MARK: - Load Shedding Test
    
    func testLoadSheddingUnderPressure() async throws {
        // Given - System with load shedding capabilities
        let pipeline = StandardPipeline()
        let loadMonitor = LoadMonitor()
        
        pipeline.use(LoadSheddingMiddleware(
            monitor: loadMonitor,
            shedStrategy: .priorityBased
        ))
        pipeline.use(PriorityQueuingMiddleware())
        pipeline.use(BackPressureMiddleware(maxQueueSize: 50))
        pipeline.use(AdaptiveTimeoutMiddleware())
        
        pipeline.registerHandler { (command: PrioritizedCommand, context: Context) in
            // Simulate variable processing time
            let processingTime = Double.random(in: 0.01...0.1)
            try await Task.sleep(nanoseconds: UInt64(processingTime * 1_000_000_000))
            
            return ProcessingResult(
                commandId: command.id,
                priority: command.priority,
                processedAt: Date()
            )
        }
        
        // When - Generate high load with mixed priorities
        let loadGenerator = LoadGenerator()
        let results = try await loadGenerator.generateLoad(
            pipeline: pipeline,
            duration: 2.0,
            requestsPerSecond: 200,
            priorityDistribution: [
                .critical: 0.1,
                .high: 0.2,
                .normal: 0.5,
                .low: 0.2
            ]
        )
        
        // Then - Verify load shedding behavior
        let totalRequests = results.attempted
        let successfulRequests = results.successful
        let shedRequests = results.shed
        
        print("""
        Load Shedding Results:
        - Total Attempted: \(totalRequests)
        - Successful: \(successfulRequests)
        - Shed: \(shedRequests)
        - Success Rate: \(String(format: "%.2f%%", Double(successfulRequests) / Double(totalRequests) * 100))
        """)
        
        // Verify critical requests were prioritized
        let criticalSuccess = results.successByPriority[.critical] ?? 0
        let criticalAttempted = results.attemptedByPriority[.critical] ?? 1
        let criticalSuccessRate = Double(criticalSuccess) / Double(criticalAttempted)
        
        let lowSuccess = results.successByPriority[.low] ?? 0
        let lowAttempted = results.attemptedByPriority[.low] ?? 1
        let lowSuccessRate = Double(lowSuccess) / Double(lowAttempted)
        
        XCTAssertGreaterThan(
            criticalSuccessRate,
            lowSuccessRate,
            "Critical requests should have higher success rate than low priority"
        )
        
        // Verify load shedding occurred
        XCTAssertGreaterThan(shedRequests, 0, "Some requests should be shed under high load")
        
        // Verify system remained responsive
        let p99Latency = results.latencyPercentile(99)
        XCTAssertLessThan(p99Latency, 1.0, "P99 latency should remain under 1 second")
    }
    
    // MARK: - Chaos Engineering Test
    
    func testChaosEngineeringScenarios() async throws {
        // Given - System with chaos injection
        let pipeline = StandardPipeline()
        let chaosMonkey = ChaosMonkey(
            config: ChaosConfig(
                failureRate: 0.1,
                latencyRate: 0.2,
                latencyRange: 0.1...0.5,
                resourceExhaustionRate: 0.05
            )
        )
        
        pipeline.use(ChaosMiddleware(chaosMonkey: chaosMonkey))
        pipeline.use(ObservabilityMiddleware())
        pipeline.use(ResilienceMetricsMiddleware())
        
        // Standard resilience stack
        pipeline.use(CircuitBreakerMiddleware(breaker: AdaptiveCircuitBreaker()))
        pipeline.use(RetryMiddleware(maxAttempts: 3))
        pipeline.use(TimeoutMiddleware(timeout: 1.0))
        pipeline.use(BulkheadMiddleware(maxConcurrency: 20))
        
        pipeline.registerHandler { (command: TestCommand, context: Context) in
            return "Success despite chaos"
        }
        
        // When - Run system under chaos
        let testDuration: TimeInterval = 5.0
        let startTime = CFAbsoluteTimeGetCurrent()
        var successCount = 0
        var failureReasons: [String: Int] = [:]
        
        while CFAbsoluteTimeGetCurrent() - startTime < testDuration {
            await withTaskGroup(of: Result<String, Error>.self) { group in
                // Concurrent requests
                for _ in 0..<10 {
                    group.addTask {
                        do {
                            let result = try await pipeline.execute(
                                TestCommand(),
                                context: CommandContext.test()
                            )
                            return .success(result)
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                
                for await result in group {
                    switch result {
                    case .success:
                        successCount += 1
                    case .failure(let error):
                        let reason = String(describing: type(of: error))
                        failureReasons[reason, default: 0] += 1
                    }
                }
            }
            
            // Brief pause between batches
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        
        // Then - System should maintain acceptable success rate
        let totalAttempts = successCount + failureReasons.values.reduce(0, +)
        let successRate = Double(successCount) / Double(totalAttempts)
        
        print("""
        Chaos Test Results:
        - Success Rate: \(String(format: "%.2f%%", successRate * 100))
        - Failure Reasons: \(failureReasons)
        """)
        
        XCTAssertGreaterThan(successRate, 0.7, "System should maintain >70% success rate under chaos")
        
        // Verify different failure modes were triggered
        XCTAssertGreaterThan(failureReasons.count, 1, "Multiple failure types should occur")
    }
}

// MARK: - Test Support Types

struct ComplexOperationCommand: Command {
    typealias Output = ComplexOperationResult
    let id: String
}

struct ComplexOperationResult {
    let resultA: String
    let resultB: String
    let resultC: String
    let degraded: Bool
}

struct FeatureRichCommand: Command {
    typealias Output = FeatureRichResult
}

struct FeatureRichResult {
    let data: String
    let enabledFeatures: [String]
    let performanceMode: String
}

struct OrderSagaCommand: Command {
    typealias Output = OrderSagaResult
    let orderId: String
}

struct OrderSagaResult {
    let success: Bool
    let completedSteps: [String]
    let compensatedSteps: [String]
}

struct PrioritizedCommand: Command {
    typealias Output = ProcessingResult
    
    let id: String
    let priority: Priority
    
    enum Priority: Int {
        case low = 0
        case normal = 1
        case high = 2
        case critical = 3
    }
}

struct ProcessingResult {
    let commandId: String
    let priority: PrioritizedCommand.Priority
    let processedAt: Date
}

// Mock services
class FailingService {
    let name: String
    let failureRate: Double
    
    init(name: String, failureRate: Double) {
        self.name = name
        self.failureRate = failureRate
    }
    
    func execute() async throws -> String {
        if Double.random(in: 0...1) < failureRate {
            throw ServiceError.serviceUnavailable(name)
        }
        return "\(name) result"
    }
}

enum ServiceError: Error {
    case serviceUnavailable(String)
}

// Feature flags
class FeatureFlags {
    private var flags: [String: Bool] = [:]
    
    func setAll(enabled: Bool) {
        flags = [
            "recommendations": enabled,
            "analytics": enabled,
            "personalization": enabled
        ]
    }
    
    func disable(_ features: [String]) {
        for feature in features {
            flags[feature] = false
        }
    }
    
    func isEnabled(_ feature: String) -> Bool {
        flags[feature] ?? false
    }
}

// Saga implementation
class SagaCoordinator {
    private var sagas: [String: Saga] = [:]
    private var transactionStates: [TransactionState] = []
    
    func register(saga: Saga) {
        sagas[saga.name] = saga
    }
    
    func execute(sagaName: String, context: Context) async throws -> SagaExecutionResult {
        guard let saga = sagas[sagaName] else {
            throw SagaError.sagaNotFound
        }
        
        var completedSteps: [String] = []
        var compensatedSteps: [String] = []
        
        for step in saga.steps {
            do {
                try await step.forward(context)
                completedSteps.append(step.name)
            } catch {
                // Compensate in reverse order
                for completedStep in completedSteps.reversed() {
                    if let stepToCompensate = saga.steps.first(where: { $0.name == completedStep }) {
                        try? await stepToCompensate.compensate(context)
                        compensatedSteps.append(completedStep)
                    }
                }
                
                let state = TransactionState(
                    success: false,
                    completedSteps: completedSteps,
                    compensatedSteps: compensatedSteps
                )
                transactionStates.append(state)
                
                return SagaExecutionResult(
                    success: false,
                    completedSteps: completedSteps,
                    compensatedSteps: compensatedSteps
                )
            }
        }
        
        let state = TransactionState(
            success: true,
            completedSteps: completedSteps,
            compensatedSteps: compensatedSteps
        )
        transactionStates.append(state)
        
        return SagaExecutionResult(
            success: true,
            completedSteps: completedSteps,
            compensatedSteps: compensatedSteps
        )
    }
    
    func getAllTransactionStates() -> [TransactionState] {
        transactionStates
    }
}

struct Saga {
    let name: String
    let steps: [SagaStep]
}

struct SagaStep {
    let name: String
    let forward: (Context) async throws -> Void
    let compensate: (Context) async throws -> Void
}

struct SagaExecutionResult {
    let success: Bool
    let completedSteps: [String]
    let compensatedSteps: [String]
}

struct TransactionState {
    let success: Bool
    let completedSteps: [String]
    let compensatedSteps: [String]
}

enum SagaError: Error {
    case sagaNotFound
    case stepFailed(String)
    case preconditionFailed
}

// Load testing utilities
class LoadMonitor {
    private var currentLoad: Double = 0
    
    func getCurrentLoad() -> Double {
        currentLoad
    }
    
    func recordRequest() {
        currentLoad = min(currentLoad + 0.01, 1.0)
    }
    
    func recordCompletion() {
        currentLoad = max(currentLoad - 0.01, 0)
    }
}

class LoadGenerator {
    struct LoadResult {
        let attempted: Int
        let successful: Int
        let shed: Int
        let attemptedByPriority: [PrioritizedCommand.Priority: Int]
        let successByPriority: [PrioritizedCommand.Priority: Int]
        let latencies: [TimeInterval]
        
        func latencyPercentile(_ percentile: Int) -> TimeInterval {
            let sorted = latencies.sorted()
            let index = Int(Double(sorted.count) * Double(percentile) / 100.0)
            return sorted[min(index, sorted.count - 1)]
        }
    }
    
    func generateLoad(
        pipeline: Pipeline,
        duration: TimeInterval,
        requestsPerSecond: Int,
        priorityDistribution: [PrioritizedCommand.Priority: Double]
    ) async throws -> LoadResult {
        var attempted = 0
        var successful = 0
        var shed = 0
        var attemptedByPriority: [PrioritizedCommand.Priority: Int] = [:]
        var successByPriority: [PrioritizedCommand.Priority: Int] = [:]
        var latencies: [TimeInterval] = []
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let requestInterval = 1.0 / Double(requestsPerSecond)
        
        while CFAbsoluteTimeGetCurrent() - startTime < duration {
            let priority = selectPriority(from: priorityDistribution)
            let command = PrioritizedCommand(
                id: UUID().uuidString,
                priority: priority
            )
            
            attempted += 1
            attemptedByPriority[priority, default: 0] += 1
            
            let requestStart = CFAbsoluteTimeGetCurrent()
            
            do {
                _ = try await pipeline.execute(command, context: CommandContext.test())
                successful += 1
                successByPriority[priority, default: 0] += 1
                
                let latency = CFAbsoluteTimeGetCurrent() - requestStart
                latencies.append(latency)
            } catch is LoadSheddingError {
                shed += 1
            } catch {
                // Other errors
            }
            
            // Wait for next request
            try await Task.sleep(nanoseconds: UInt64(requestInterval * 1_000_000_000))
        }
        
        return LoadResult(
            attempted: attempted,
            successful: successful,
            shed: shed,
            attemptedByPriority: attemptedByPriority,
            successByPriority: successByPriority,
            latencies: latencies
        )
    }
    
    private func selectPriority(
        from distribution: [PrioritizedCommand.Priority: Double]
    ) -> PrioritizedCommand.Priority {
        let random = Double.random(in: 0...1)
        var cumulative = 0.0
        
        for (priority, probability) in distribution.sorted(by: { $0.key.rawValue > $1.key.rawValue }) {
            cumulative += probability
            if random <= cumulative {
                return priority
            }
        }
        
        return .normal
    }
}

struct LoadSheddingError: Error {}

// Chaos engineering
class ChaosMonkey {
    let config: ChaosConfig
    
    init(config: ChaosConfig) {
        self.config = config
    }
    
    func shouldInjectFailure() -> Bool {
        Double.random(in: 0...1) < config.failureRate
    }
    
    func shouldInjectLatency() -> Bool {
        Double.random(in: 0...1) < config.latencyRate
    }
    
    func getLatency() -> TimeInterval {
        Double.random(in: config.latencyRange)
    }
    
    func shouldExhaustResources() -> Bool {
        Double.random(in: 0...1) < config.resourceExhaustionRate
    }
}

struct ChaosConfig {
    let failureRate: Double
    let latencyRate: Double
    let latencyRange: ClosedRange<Double>
    let resourceExhaustionRate: Double
}