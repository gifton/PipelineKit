import XCTest
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
        
        init(name: String) {
            self.name = name
        }
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            executionLog.append("[\(name)] Before")
            let result = try await next(command, metadata)
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
        let pipeline = try await pipeline(for: handler)
            <+ auth
            <+ validation
            .build()
        
        // Then
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
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
        let pipeline = try await pipeline(for: handler)
            <++ middleware(critical, priority: .critical)
            <+ normal  // Default priority (.normal)
            <++ middleware(monitoring, priority: .monitoring)
            .build()
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline.execute(command, metadata: DefaultCommandMetadata())
        
        // Verify all middleware executed
        XCTAssertFalse(await critical.getExecutionLog().isEmpty)
        XCTAssertFalse(await normal.getExecutionLog().isEmpty)
        XCTAssertFalse(await monitoring.getExecutionLog().isEmpty)
    }
    
    // MARK: - Pipeline Composition Tests
    
    func testPipelineCompositionOperator() async throws {
        // Given
        let handler = TestHandler()
        
        // Create sub-pipelines
        let authPipeline = try await pipeline(for: handler)
            <+ TrackingMiddleware(name: "Auth1")
            <+ TrackingMiddleware(name: "Auth2")
            .build()
        
        let validationPipeline = try await pipeline(for: handler)
            <+ TrackingMiddleware(name: "Validation1")
            <+ TrackingMiddleware(name: "Validation2")
            .build()
        
        // When - Compose pipelines
        let composedPipeline = authPipeline |> validationPipeline
        
        // Then
        let command = TestCommand(value: "test")
        let result = try await composedPipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(result, "Handled: test")
    }
    
    // MARK: - Conditional Operator Tests
    
    func testConditionalPipelineOperator() async throws {
        // Given
        let handler = TestHandler()
        let mainMiddleware = TrackingMiddleware(name: "Main")
        let conditionalMiddleware = TrackingMiddleware(name: "Conditional")
        
        var shouldExecute = true
        
        // When
        let basePipeline = try await pipeline(for: handler)
            <+ mainMiddleware
            .build()
        
        let conditionalPipeline = try await pipeline(for: handler)
            <+ conditionalMiddleware
            .build()
        
        let finalPipeline = basePipeline |? { shouldExecute } |> conditionalPipeline
        
        // Then - With condition true
        let command = TestCommand(value: "test")
        _ = try await finalPipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertFalse(await mainMiddleware.getExecutionLog().isEmpty)
        XCTAssertFalse(await conditionalMiddleware.getExecutionLog().isEmpty)
        
        // Reset and test with condition false
        shouldExecute = false
        let pipeline2 = basePipeline |? { shouldExecute } |> conditionalPipeline
        _ = try await pipeline2.execute(command, metadata: DefaultCommandMetadata())
        
        // Main should execute twice (once from each test), conditional only once
        XCTAssertEqual(await mainMiddleware.getExecutionLog().count, 4) // 2 executions * 2 logs each
    }
    
    // MARK: - Error Handling Operator Tests
    
    actor ErrorThrowingMiddleware: Middleware {
        let shouldThrow: Bool
        
        init(shouldThrow: Bool) {
            self.shouldThrow = shouldThrow
        }
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            if shouldThrow {
                throw TestError.simulatedError
            }
            return try await next(command, metadata)
        }
    }
    
    enum TestError: Error {
        case simulatedError
        case handledError
    }
    
    func testErrorHandlingOperator() async throws {
        // Given
        let handler = TestHandler()
        let errorMiddleware = ErrorThrowingMiddleware(shouldThrow: true)
        var errorHandled = false
        
        // When
        let basePipeline = try await pipeline(for: handler)
            <+ errorMiddleware
            .build()
        
        let safePipeline = basePipeline |! { error in
            errorHandled = true
        }
        
        // Then
        let command = TestCommand(value: "test")
        
        do {
            _ = try await safePipeline.execute(command, metadata: DefaultCommandMetadata())
            XCTFail("Expected error but succeeded")
        } catch {
            XCTAssertTrue(errorHandled)
        }
    }
    
    // MARK: - Parallel Operator Tests
    
    func testParallelPipelineOperator() async throws {
        // Given
        let handler = TestHandler()
        
        let pipeline1 = try await pipeline(for: handler)
            <+ TrackingMiddleware(name: "Pipeline1-A")
            <+ TrackingMiddleware(name: "Pipeline1-B")
            .build()
        
        let pipeline2 = try await pipeline(for: handler)
            <+ TrackingMiddleware(name: "Pipeline2-A")
            <+ TrackingMiddleware(name: "Pipeline2-B")
            .build()
        
        // When - Create parallel pipeline
        let parallelPipeline = pipeline1 || pipeline2
        
        // Then
        let command = TestCommand(value: "test")
        
        // The parallel operator should execute both pipelines
        // Note: The actual implementation might need adjustment based on how parallel execution is defined
        let result = try await parallelPipeline.execute(command, metadata: DefaultCommandMetadata())
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
        
        var featureEnabled = true
        
        // When - Build complex pipeline with multiple operators
        let authPipeline = try await pipeline(for: handler)
            <++ middleware(auth, priority: .authentication)
            .build()
        
        let validationPipeline = try await pipeline(for: handler)
            <++ middleware(validation, priority: .validation)
            .build()
        
        let processingPipeline = try await pipeline(for: handler)
            <+ processing
            .build()
        
        let monitoringPipeline = try await pipeline(for: handler)
            <+ metrics
            <+ audit
            .build()
        
        // Compose with operators
        let finalPipeline = authPipeline 
            |> validationPipeline 
            |> (processingPipeline |? { featureEnabled })
            || monitoringPipeline
        
        // Then
        let command = TestCommand(value: "test")
        let result = try await finalPipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertEqual(result, "Handled: test")
        
        // Verify execution
        XCTAssertFalse(await auth.getExecutionLog().isEmpty)
        XCTAssertFalse(await validation.getExecutionLog().isEmpty)
        XCTAssertFalse(await processing.getExecutionLog().isEmpty)
    }
    
    // MARK: - Helper Function Tests
    
    func testMiddlewareHelperFunction() async throws {
        // Given
        let testMiddleware = TrackingMiddleware(name: "Test")
        
        // When
        let wrappedMiddleware = middleware(testMiddleware, priority: .critical)
        
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
        let result = try await builtPipeline.execute(command, metadata: DefaultCommandMetadata())
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
        let pipeline1 = try await pipeline(for: handler)
            <+ m1
            <+ m2
            <+ m3
            .build()
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await pipeline1.execute(command, metadata: DefaultCommandMetadata())
        
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
        
        let finalPipeline = try await pipeline(for: handler)
            <+ operatorMiddleware
            .build()
            |> dslPipeline
        
        // Then
        let command = TestCommand(value: "test")
        _ = try await finalPipeline.execute(command, metadata: DefaultCommandMetadata())
        
        XCTAssertFalse(await dslMiddleware.getExecutionLog().isEmpty)
        XCTAssertFalse(await operatorMiddleware.getExecutionLog().isEmpty)
    }
}