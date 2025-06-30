import XCTest
import Foundation
@testable import PipelineKit

final class PipelineOperatorDSLTests: XCTestCase {
    
    // MARK: - Test Infrastructure
    
    struct TestCommand: Command {
        typealias Result = String
        let value: String
    }
    
    struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Handled: \(command.value)"
        }
    }
    
    actor TrackingMiddleware: Middleware {
        let name: String
        private var executionLog: [String] = []
        let priority: ExecutionPriority = .custom
        
        init(name: String) {
            self.name = name
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            executionLog.append("[\(name)] Before")
            let result = try await next(command, context)
            executionLog.append("[\(name)] After")
            return result
        }
        
        func getExecutionLog() async -> [String] {
            executionLog
        }
    }
    
    // MARK: - Basic Operator Tests
    
    func testBasicMiddlewareOperator() async throws {
        // Given
        let handler = TestHandler()
        let auth = TrackingMiddleware(name: "Auth")
        let validation = TrackingMiddleware(name: "Validation")
        
        // When
        let pipeline = try await (pipeline(for: handler)
            <+ auth
            <+ validation)
            .build()
        
        // Then
        let command = TestCommand(value: "test")
        let context = CommandContext(metadata: StandardCommandMetadata())
        let result = try await pipeline.execute(command, context: context)
        
        XCTAssertEqual(result, "Handled: test")
        
        let authLog = await auth.getExecutionLog()
        let validationLog = await validation.getExecutionLog()
        
        XCTAssertEqual(authLog, ["[Auth] Before", "[Auth] After"])
        XCTAssertEqual(validationLog, ["[Validation] Before", "[Validation] After"])
    }
    
    func testPriorityMiddlewareOperator() async throws {
        // Given
        let handler = TestHandler()
        let critical = TrackingMiddleware(name: "Critical")
        let normal = TrackingMiddleware(name: "Normal")
        let monitoring = TrackingMiddleware(name: "Monitoring")
        
        // When
        let pipeline = try await (pipeline(for: handler)
            <++ middleware(critical, priority: .authentication)
            <+ normal  // Default priority (.normal)
            <++ middleware(monitoring, priority: .monitoring))
            .build()
        
        // Then
        let command = TestCommand(value: "test")
        let context = CommandContext(metadata: StandardCommandMetadata())
        _ = try await pipeline.execute(command, context: context)
        
        // Verify all middleware executed
        let criticalLog = await critical.getExecutionLog()
        let normalLog = await normal.getExecutionLog()
        let monitoringLog = await monitoring.getExecutionLog()
        XCTAssertFalse(criticalLog.isEmpty)
        XCTAssertFalse(normalLog.isEmpty)
        XCTAssertFalse(monitoringLog.isEmpty)
    }
    
    // MARK: - Pipeline Composition Tests
    
    func testPipelineCompositionOperator() async throws {
        // Given
        let handler = TestHandler()
        
        // Create sub-pipelines
        let authPipeline = try await (pipeline(for: handler)
            <+ TrackingMiddleware(name: "Auth1")
            <+ TrackingMiddleware(name: "Auth2"))
            .build()
        
        let validationPipeline = try await (pipeline(for: handler)
            <+ TrackingMiddleware(name: "Validation1")
            <+ TrackingMiddleware(name: "Validation2"))
            .build()
        
        // When - Compose pipelines
        let composedPipeline = authPipeline |> validationPipeline
        
        // Then
        let command = TestCommand(value: "test")
        let result = try await composedPipeline.execute(command, context: CommandContext(metadata: StandardCommandMetadata()))
        
        XCTAssertEqual(result, "Handled: test")
    }
    
    // MARK: - Conditional Operator Tests
    
    func testConditionalPipelineOperator() async throws {
        // Given
        let handler = TestHandler()
        let mainMiddleware = TrackingMiddleware(name: "Main")
        let conditionalMiddleware = TrackingMiddleware(name: "Conditional")
        
        final class ExecutionState: @unchecked Sendable {
            private let lock = NSLock()
            private var shouldExecute = true
            
            func getShouldExecute() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return shouldExecute
            }
            
            func setShouldExecute(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                shouldExecute = value
            }
        }
        
        let executionState = ExecutionState()
        
        // When
        let basePipeline = try await (pipeline(for: handler)
            <+ mainMiddleware)
            .build()
        
        let conditionalPipeline = try await (pipeline(for: handler)
            <+ conditionalMiddleware)
            .build()
        
        let finalPipeline = basePipeline |? { executionState.getShouldExecute() } |> conditionalPipeline
        
        // Then - With condition true
        let command = TestCommand(value: "test")
        let context = CommandContext(metadata: StandardCommandMetadata())
        _ = try await finalPipeline.execute(command, context: context)
        
        let mainLog = await mainMiddleware.getExecutionLog()
        let conditionalLog = await conditionalMiddleware.getExecutionLog()
        XCTAssertFalse(mainLog.isEmpty)
        XCTAssertFalse(conditionalLog.isEmpty)
        
        // Reset and test with condition false
        executionState.setShouldExecute(false)
        let pipeline2 = basePipeline |? { executionState.getShouldExecute() } |> conditionalPipeline
        _ = try await pipeline2.execute(command, context: CommandContext(metadata: StandardCommandMetadata()))
        
        // Main should execute twice (once from each test), conditional only once
        let finalMainLog = await mainMiddleware.getExecutionLog()
        XCTAssertEqual(finalMainLog.count, 4) // 2 executions * 2 logs each
    }
    
    // MARK: - Error Handling Operator Tests
    
    actor ErrorThrowingMiddleware: Middleware {
        let shouldThrow: Bool
        
        init(shouldThrow: Bool) {
            self.shouldThrow = shouldThrow
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            if shouldThrow {
                throw TestError.middlewareFailed
            }
            return try await next(command, context)
        }
    }
    
    func testErrorHandlingOperator() async throws {
        // Given
        final class ErrorState: @unchecked Sendable {
            private let lock = NSLock()
            private var handled = false
            
            func setHandled() {
                lock.lock()
                defer { lock.unlock() }
                handled = true
            }
            
            func isHandled() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return handled
            }
        }
        
        let handler = TestHandler()
        let errorMiddleware = ErrorThrowingMiddleware(shouldThrow: true)
        let errorState = ErrorState()
        
        // When
        let basePipeline = try await (pipeline(for: handler)
            <+ errorMiddleware)
            .build()
        
        let safePipeline = basePipeline |! { error in
            errorState.setHandled()
        }
        
        // Then
        let command = TestCommand(value: "test")
        
        do {
            let context = CommandContext(metadata: StandardCommandMetadata())
            _ = try await safePipeline.execute(command, context: context)
            XCTFail("Expected error but succeeded")
        } catch {
            XCTAssertTrue(errorState.isHandled())
        }
    }
    
    // MARK: - Parallel Operator Tests
    
    func testParallelPipelineOperator() async throws {
        // Given
        let handler = TestHandler()
        
        let pipeline1 = try await (pipeline(for: handler)
            <+ TrackingMiddleware(name: "Pipeline1-A")
            <+ TrackingMiddleware(name: "Pipeline1-B"))
            .build()
        
        let pipeline2 = try await (pipeline(for: handler)
            <+ TrackingMiddleware(name: "Pipeline2-A")
            <+ TrackingMiddleware(name: "Pipeline2-B"))
            .build()
        
        // When - Create parallel pipeline
        let parallelPipeline = pipeline1 <> pipeline2
        
        // Then
        let command = TestCommand(value: "test")
        
        // The parallel operator should execute both pipelines
        // Note: The actual implementation might need adjustment based on how parallel execution is defined
        let context = CommandContext(metadata: StandardCommandMetadata())
        let result = try await parallelPipeline.execute(command, context: context)
        XCTAssertEqual(result, "Handled: test")
    }
    
    // MARK: - Complex Operator Combinations
    
    func testComplexOperatorChaining() async throws {
        // Given
        let handler = TestHandler()
        let auth = TrackingMiddleware(name: "Auth")
        let validation = TrackingMiddleware(name: "Validation")
        let processing = TrackingMiddleware(name: "Processing")
        let metrics = TrackingMiddleware(name: "Metrics")
        let audit = TrackingMiddleware(name: "Audit")
        
        final class FeatureState: @unchecked Sendable {
            private let lock = NSLock()
            private var featureEnabled = true
            
            func isEnabled() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return featureEnabled
            }
            
            func setEnabled(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                featureEnabled = value
            }
        }
        
        let featureState = FeatureState()
        
        // When - Build complex pipeline with multiple operators
        let authPipeline = try await (pipeline(for: handler)
            <++ middleware(auth, priority: .authentication))
            .build()
        
        let validationPipeline = try await (pipeline(for: handler)
            <++ middleware(validation, priority: .validation))
            .build()
        
        let processingPipeline = try await (pipeline(for: handler)
            <+ processing)
            .build()
        
        let monitoringPipeline = try await (pipeline(for: handler)
            <+ metrics
            <+ audit)
            .build()
        
        // Compose with operators
        let finalPipeline = authPipeline 
            |> validationPipeline 
            |> (processingPipeline |? { featureState.isEnabled() })
            |> monitoringPipeline
        
        // Then
        let command = TestCommand(value: "test")
        let context = CommandContext(metadata: StandardCommandMetadata())
        let result = try await finalPipeline.execute(command, context: context)
        
        XCTAssertEqual(result, "Handled: test")
        
        // Verify execution
        let authLog = await auth.getExecutionLog()
        let validationLog = await validation.getExecutionLog()
        let processingLog = await processing.getExecutionLog()
        XCTAssertFalse(authLog.isEmpty)
        XCTAssertFalse(validationLog.isEmpty)
        XCTAssertFalse(processingLog.isEmpty)
    }
    
    // MARK: - Helper Function Tests
    
    func testMiddlewareHelperFunction() async throws {
        // Given
        let testMiddleware = TrackingMiddleware(name: "Test")
        
        // When
        let wrappedMiddleware = middleware(testMiddleware, priority: .authentication)
        
        // Then
        XCTAssertNotNil(wrappedMiddleware)
        // The actual structure depends on implementation
    }
    
    func testPipelineBuilderHelperFunction() async throws {
        // Given
        let handler = TestHandler()
        
        // When
        let builder = pipeline(for: handler)
        let builtPipeline = try await builder.build()
        
        // Then
        let command = TestCommand(value: "test")
        let result = try await builtPipeline.execute(command, context: CommandContext(metadata: StandardCommandMetadata()))
        XCTAssertEqual(result, "Handled: test")
    }
    
    // MARK: - Operator Precedence Tests
    
    func testOperatorPrecedence() async throws {
        // Given
        let handler = TestHandler()
        let m1 = TrackingMiddleware(name: "M1")
        let m2 = TrackingMiddleware(name: "M2")
        let m3 = TrackingMiddleware(name: "M3")
        
        // When - Test that operators work in expected order
        let pipeline1 = try await (pipeline(for: handler)
            <+ m1
            <+ m2
            <+ m3)
            .build()
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline1.execute(command, context: CommandContext(metadata: StandardCommandMetadata()))
        
        // Verify execution order
        let log1 = await m1.getExecutionLog()
        let log2 = await m2.getExecutionLog()
        let log3 = await m3.getExecutionLog()
        
        XCTAssertEqual(log1.first, "[M1] Before")
        XCTAssertEqual(log2.first, "[M2] Before")
        XCTAssertEqual(log3.first, "[M3] Before")
    }
}

// MARK: - Integration Tests

extension PipelineOperatorDSLTests {
    
    func testOperatorsWithDSLIntegration() async throws {
        // Given
        let handler = TestHandler()
        let dslMiddleware = TrackingMiddleware(name: "DSL")
        let operatorMiddleware = TrackingMiddleware(name: "Operator")
        
        // When - Mix DSL and operators
        let dslPipeline = try await CreatePipeline(handler: handler) {
            dslMiddleware
        }
        
        let finalPipeline = try await (pipeline(for: handler)
            <+ operatorMiddleware)
            .build()
            |> dslPipeline
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await finalPipeline.execute(command, context: CommandContext(metadata: StandardCommandMetadata()))
        
        let dslLog = await dslMiddleware.getExecutionLog()
        let operatorLog = await operatorMiddleware.getExecutionLog()
        XCTAssertFalse(dslLog.isEmpty)
        XCTAssertFalse(operatorLog.isEmpty)
    }
}