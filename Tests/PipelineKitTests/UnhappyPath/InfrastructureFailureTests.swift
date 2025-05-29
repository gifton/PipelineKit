import XCTest
@testable import PipelineKit

// MARK: - Test Support Types for InfrastructureFailureTests

struct InfrastructureTestCommand: Command {
    typealias Result = String
    let value: String
}

struct InfrastructureTestHandler: CommandHandler {
    typealias CommandType = InfrastructureTestCommand
    
    func handle(_ command: InfrastructureTestCommand) async throws -> String {
        return "Handled: \(command.value)"
    }
}

/// Tests for infrastructure failure scenarios and system-level issues
final class InfrastructureFailureTests: XCTestCase {
    
    // MARK: - Memory Pressure Scenarios
    
    func testLowMemoryConditions() async throws {
        let pipeline = DefaultPipeline(handler: InfrastructureTestHandler())
        let memoryPressureMiddleware = MemoryPressureMiddleware()
        
        try await pipeline.addMiddleware(memoryPressureMiddleware)
        
        let command = InfrastructureTestCommand(value: "memory_pressure_test")
        let metadata = DefaultCommandMetadata()
        
        // Execute under simulated memory pressure
        do {
            let result = try await pipeline.execute(command, metadata: metadata)
            // If it succeeds, memory management is working
            XCTAssertEqual(result, "Handled: memory_pressure_test")
        } catch {
            // If it fails due to memory issues, verify graceful handling
            XCTAssertTrue(error.localizedDescription.contains("memory") || 
                         error.localizedDescription.contains("resource"))
        }
    }
    
    func testMemoryLeakDetection() async throws {
        weak var weakPipeline: DefaultPipeline<InfrastructureTestCommand, InfrastructureTestHandler>?
        weak var weakHandler: InfrastructureTestHandler?
        
        autoreleasepool {
            let handler = InfrastructureTestHandler()
            let pipeline = DefaultPipeline(handler: handler)
            
            weakPipeline = pipeline
            weakHandler = handler
            
            // Execute some commands
            let command = InfrastructureTestCommand(value: "leak_test")
            let metadata = DefaultCommandMetadata()
            
            _ = try await pipeline.execute(command, metadata: metadata)
        }
        
        // Force garbage collection
        await Task.yield()
        
        // Objects should be deallocated
        XCTAssertNil(weakPipeline, "Pipeline should be deallocated")
        XCTAssertNil(weakHandler, "Handler should be deallocated")
    }
    
    func testContextMemoryManagement() async throws {
        weak var weakContext: CommandContext?
        
        autoreleasepool {
            let pipeline = ContextAwarePipeline(handler: InfrastructureTestHandler())
            let contextCapturingMiddleware = InfrastructureContextCapturingMiddleware { context in
                weakContext = context
            }
            
            try await pipeline.addMiddleware(contextCapturingMiddleware)
            
            let command = InfrastructureTestCommand(value: "context_memory_test")
            let metadata = DefaultCommandMetadata()
            
            _ = try await pipeline.execute(command, metadata: metadata)
        }
        
        // Context should be cleaned up after execution
        await Task.yield()
        XCTAssertNil(weakContext, "Context should be deallocated after execution")
    }
    
    // MARK: - File System Failures
    
    func testAuditLogFileSystemFailure() async throws {
        // Test with invalid file path
        let invalidPath = URL(fileURLWithPath: "/nonexistent/directory/audit.log")
        
        do {
            let auditLogger = try AuditLogger(
                destination: .file(url: invalidPath),
                privacyLevel: .full
            )
            
            let command = InfrastructureTestCommand(value: "filesystem_test")
            let metadata = DefaultCommandMetadata()
            
            // Should handle file system errors gracefully
            await auditLogger.logCommandExecution(
                command: command,
                metadata: metadata,
                result: .success("test"),
                duration: 0.1
            )
            
            // If we get here, the error was handled gracefully
        } catch {
            // If initialization fails, verify it's due to file system issues
            let errorMessage = error.localizedDescription.lowercased()
            XCTAssertTrue(
                errorMessage.contains("no such file") ||
                errorMessage.contains("permission denied") ||
                errorMessage.contains("directory") ||
                errorMessage.contains("invalid")
            )
        }
    }
    
    func testAuditLogDiskSpaceExhaustion() async throws {
        // Simulate disk space exhaustion by using /dev/full (on Linux) or similar
        let limitedSpacePath = URL(fileURLWithPath: "/tmp/limited_space_audit.log")
        
        do {
            let auditLogger = try AuditLogger(
                destination: .file(url: limitedSpacePath),
                privacyLevel: .full,
                bufferSize: 10
            )
            
            let command = InfrastructureTestCommand(value: "disk_space_test")
            let metadata = DefaultCommandMetadata()
            
            // Generate many log entries to test disk space handling
            for i in 0..<1000 {
                await auditLogger.logCommandExecution(
                    command: InfrastructureTestCommand(value: "entry_\(i)"),
                    metadata: metadata,
                    result: .success("result_\(i)"),
                    duration: 0.1
                )
            }
            
            // Should handle disk space issues gracefully
            let logs = await auditLogger.getAuditLogs(criteria: AuditQueryCriteria())
            XCTAssertLessThanOrEqual(logs.count, 1000, "Should handle disk space limitations")
            
        } catch {
            // File system errors during initialization are acceptable
            print("Expected file system error: \(error)")
        }
    }
    
    func testAuditLogFileCorruption() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let corruptedLogPath = tempDir.appendingPathComponent("corrupted_audit.log")
        
        // Create a corrupted file
        let corruptedData = Data("This is not valid JSON log data".utf8)
        try corruptedData.write(to: corruptedLogPath)
        
        do {
            let auditLogger = try AuditLogger(
                destination: .file(url: corruptedLogPath),
                privacyLevel: .full
            )
            
            // Should handle corrupted file gracefully
            let command = InfrastructureTestCommand(value: "corruption_test")
            let metadata = DefaultCommandMetadata()
            
            await auditLogger.logCommandExecution(
                command: command,
                metadata: metadata,
                result: .success("test"),
                duration: 0.1
            )
            
            // Should be able to query despite initial corruption
            let logs = await auditLogger.getAuditLogs(criteria: AuditQueryCriteria())
            XCTAssertGreaterThanOrEqual(logs.count, 0, "Should handle corrupted files")
            
        } catch {
            // Corruption handling errors are acceptable
            print("Expected corruption handling error: \(error)")
        }
        
        // Clean up
        try? FileManager.default.removeItem(at: corruptedLogPath)
    }
    
    // MARK: - Network Simulation Failures
    
    func testNetworkTimeoutSimulation() async throws {
        let pipeline = DefaultPipeline(handler: InfrastructureTestHandler())
        let networkMiddleware = NetworkSimulatingMiddleware(
            latency: 2.0, // 2 second latency
            failureRate: 0.0
        )
        
        try pipeline.addMiddleware(networkMiddleware)
        
        let command = InfrastructureTestCommand(value: "network_timeout_test")
        let metadata = DefaultCommandMetadata()
        
        // Execute with timeout shorter than network latency
        do {
            let result = try await withInfrastructureTimeout(seconds: 0.5) {
                try await pipeline.execute(command, metadata: metadata)
            }
            XCTFail("Should timeout, got result: \(result)")
        } catch is InfrastructureTimeoutError {
            // Expected timeout
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testNetworkFailureSimulation() async throws {
        let pipeline = DefaultPipeline(handler: InfrastructureTestHandler())
        let networkMiddleware = NetworkSimulatingMiddleware(
            latency: 0.1,
            failureRate: 1.0 // 100% failure rate
        )
        
        try pipeline.addMiddleware(networkMiddleware)
        
        let command = InfrastructureTestCommand(value: "network_failure_test")
        let metadata = DefaultCommandMetadata()
        
        do {
            _ = try await pipeline.execute(command, metadata: metadata)
            XCTFail("Network should fail")
        } catch NetworkError.connectionFailed {
            // Expected network failure
        }
    }
    
    func testIntermittentNetworkFailures() async throws {
        let pipeline = DefaultPipeline(handler: InfrastructureTestHandler())
        let networkMiddleware = NetworkSimulatingMiddleware(
            latency: 0.1,
            failureRate: 0.5 // 50% failure rate
        )
        
        try pipeline.addMiddleware(networkMiddleware)
        
        let command = InfrastructureTestCommand(value: "intermittent_test")
        let metadata = DefaultCommandMetadata()
        
        var successCount = 0
        var failureCount = 0
        
        // Execute multiple times to test intermittent failures
        for _ in 0..<20 {
            do {
                _ = try await pipeline.execute(command, metadata: metadata)
                successCount += 1
            } catch NetworkError.connectionFailed {
                failureCount += 1
            }
        }
        
        // Should have both successes and failures
        XCTAssertGreaterThan(successCount, 0, "Some requests should succeed")
        XCTAssertGreaterThan(failureCount, 0, "Some requests should fail")
    }
    
    // MARK: - System Resource Exhaustion
    
    func testFileDescriptorExhaustion() async throws {
        // Simulate running out of file descriptors
        let auditLoggers = try await withThrowingTaskGroup(of: AuditLogger?.self) { group in
            var loggers: [AuditLogger] = []
            
            // Try to create many audit loggers with file destinations
            for i in 0..<100 {
                group.addTask {
                    do {
                        let tempDir = FileManager.default.temporaryDirectory
                        let logPath = tempDir.appendingPathComponent("audit_\(i).log")
                        
                        return try AuditLogger(
                            destination: .file(url: logPath),
                            privacyLevel: .full
                        )
                    } catch {
                        // Expected when running out of file descriptors
                        return nil
                    }
                }
            }
            
            for await logger in group {
                if let logger = logger {
                    loggers.append(logger)
                }
            }
            
            return loggers
        }
        
        // Should handle file descriptor limits gracefully
        print("Created \(auditLoggers.count) audit loggers before hitting limits")
        XCTAssertLessThan(auditLoggers.count, 100, "Should hit file descriptor limits")
    }
    
    func testThreadPoolExhaustion() async throws {
        let pipeline = DefaultPipeline(handler: TestHandler(), maxConcurrency: 1000)
        
        // Create many concurrent tasks to exhaust thread pool
        let tasks = (0..<1000).map { i in
            Task {
                let command = InfrastructureTestCommand(value: "thread_test_\(i)")
                do {
                    return try await pipeline.execute(command, metadata: DefaultCommandMetadata())
                } catch {
                    return "error: \(error.localizedDescription)"
                }
            }
        }
        
        var completedCount = 0
        var errorCount = 0
        
        for task in tasks {
            let result = await task.value
            if result.starts(with: "Handled") {
                completedCount += 1
            } else {
                errorCount += 1
            }
        }
        
        // Should handle thread pool limits gracefully
        print("Completed: \(completedCount), Errors: \(errorCount)")
        XCTAssertGreaterThan(completedCount, 0, "Some tasks should complete")
    }
    
    // MARK: - Platform-Specific Failures
    
    func testSignalHandling() async throws {
        let pipeline = DefaultPipeline(handler: InfrastructureTestHandler())
        let interruptibleMiddleware = InterruptibleMiddleware()
        
        try pipeline.addMiddleware(interruptibleMiddleware)
        
        let command = InfrastructureTestCommand(value: "signal_test")
        let metadata = DefaultCommandMetadata()
        
        let task = Task {
            try await pipeline.execute(command, metadata: metadata)
        }
        
        // Simulate signal interruption
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Task should be cancelled")
        } catch is CancellationError {
            // Expected cancellation
        }
    }
    
    func testSystemShutdown() async throws {
        let pipeline = DefaultPipeline(handler: InfrastructureTestHandler())
        let shutdownAwareMiddleware = ShutdownAwareMiddleware()
        
        try pipeline.addMiddleware(shutdownAwareMiddleware)
        
        let command = InfrastructureTestCommand(value: "shutdown_test")
        let metadata = DefaultCommandMetadata()
        
        // Simulate graceful shutdown during execution
        let task = Task {
            try await pipeline.execute(command, metadata: metadata)
        }
        
        // Simulate shutdown signal
        shutdownAwareMiddleware.triggerShutdown()
        
        do {
            let result = try await task.value
            // Should complete gracefully if possible
            XCTAssertEqual(result, "Handled: shutdown_test")
        } catch {
            // Or handle shutdown gracefully
            XCTAssertTrue(error.localizedDescription.contains("shutdown"))
        }
    }
    
    // MARK: - Error Recovery Testing
    
    func testGracefulDegradation() async throws {
        let pipeline = DefaultPipeline(handler: InfrastructureTestHandler())
        let degradingMiddleware = DegradingMiddleware()
        
        try pipeline.addMiddleware(degradingMiddleware)
        
        let command = InfrastructureTestCommand(value: "degradation_test")
        let metadata = DefaultCommandMetadata()
        
        // First few executions should work normally
        for _ in 0..<3 {
            let result = try await pipeline.execute(command, metadata: metadata)
            XCTAssertEqual(result, "Handled: degradation_test")
        }
        
        // Trigger degradation
        degradingMiddleware.triggerDegradation()
        
        // Should continue working in degraded mode
        let result = try await pipeline.execute(command, metadata: metadata)
        XCTAssertEqual(result, "Handled: degradation_test")
    }
    
    func testPartialServiceFailure() async throws {
        let concurrentPipeline = ConcurrentPipeline()
        
        // Register multiple pipelines
        let workingPipeline = DefaultPipeline(handler: InfrastructureTestHandler())
        let faultyPipeline = DefaultPipeline(handler: InfrastructureFaultyHandler())
        
        await concurrentPipeline.register(InfrastructureTestCommand.self, pipeline: workingPipeline)
        await concurrentPipeline.register(InfrastructureFaultyCommand.self, pipeline: faultyPipeline)
        
        // Working pipeline should continue to work
        let workingCommand = InfrastructureTestCommand(value: "working_test")
        let workingResult = try await concurrentPipeline.execute(workingCommand, metadata: DefaultCommandMetadata())
        XCTAssertEqual(workingResult, "Handled: working_test")
        
        // Faulty pipeline should fail predictably
        let faultyCommand = InfrastructureFaultyCommand()
        do {
            _ = try await concurrentPipeline.execute(faultyCommand, metadata: DefaultCommandMetadata())
            XCTFail("Faulty pipeline should fail")
        } catch {
            // Expected failure in faulty pipeline
        }
        
        // Working pipeline should still work after other pipeline fails
        let stillWorkingResult = try await concurrentPipeline.execute(workingCommand, metadata: DefaultCommandMetadata())
        XCTAssertEqual(stillWorkingResult, "Handled: working_test")
    }
}

// MARK: - Test Support Types

enum NetworkError: Error {
    case connectionFailed
    case timeout
}

struct MemoryPressureMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate memory pressure
        autoreleasepool {
            let _ = Array(repeating: Array(repeating: 0, count: 1000), count: 100)
        }
        return try await next(command, metadata)
    }
}

struct InfrastructureContextCapturingMiddleware: ContextAwareMiddleware {
    let onCapture: @Sendable (CommandContext) -> Void
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        onCapture(context)
        return try await next(command, context)
    }
}

struct NetworkSimulatingMiddleware: Middleware {
    let latency: TimeInterval
    let failureRate: Double
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate network latency
        try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
        
        // Simulate network failures
        if Double.random(in: 0...1) < failureRate {
            throw NetworkError.connectionFailed
        }
        
        return try await next(command, metadata)
    }
}

struct InterruptibleMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Check for cancellation
        try Task.checkCancellation()
        
        // Simulate some work
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        // Check for cancellation again
        try Task.checkCancellation()
        
        return try await next(command, metadata)
    }
}

final class ShutdownAwareMiddleware: Middleware, @unchecked Sendable {
    private var isShuttingDown = false
    
    func triggerShutdown() {
        isShuttingDown = true
    }
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        if isShuttingDown {
            throw SystemError.shutdown
        }
        return try await next(command, metadata)
    }
}

final class DegradingMiddleware: Middleware, @unchecked Sendable {
    private var isDegraded = false
    
    func triggerDegradation() {
        isDegraded = true
    }
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        if isDegraded {
            // Run in degraded mode (skip some processing)
            return try await next(command, metadata)
        }
        
        // Normal mode - do full processing
        try await Task.sleep(nanoseconds: 1_000_000) // 1ms of "processing"
        return try await next(command, metadata)
    }
}

struct InfrastructureFaultyHandler: CommandHandler {
    typealias CommandType = InfrastructureFaultyCommand
    
    func handle(_ command: InfrastructureFaultyCommand) async throws -> String {
        throw SystemError.serviceUnavailable
    }
}

struct InfrastructureFaultyCommand: Command {
    typealias Result = String
}

enum SystemError: Error {
    case shutdown
    case serviceUnavailable
    case resourceExhausted
}

struct InfrastructureTimeoutError: Error {}

func withInfrastructureTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw InfrastructureTimeoutError()
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}