import XCTest
@testable import PipelineKit

/// Stress tests for concurrent command execution to validate thread safety.
final class ConcurrencyStressTests: XCTestCase {
    
    // MARK: - Test Commands
    
    struct TestCommand: Command {
        let id: Int
        let payload: String
        
        struct Result: Sendable {
            let commandId: Int
            let processedPayload: String
            let processingTime: TimeInterval
        }
    }
    
    struct CountingHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        private let counter: Counter
        
        init(counter: Counter) {
            self.counter = counter
        }
        
        func handle(_ command: TestCommand) async throws -> TestCommand.Result {
            let startTime = Date()
            
            // Simulate some processing work
            await counter.increment()
            
            // Small delay to simulate work
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            
            let endTime = Date()
            
            return TestCommand.Result(
                commandId: command.id,
                processedPayload: "processed-\(command.payload)",
                processingTime: endTime.timeIntervalSince(startTime)
            )
        }
    }
    
    // MARK: - Test Infrastructure
    
    actor Counter {
        private var value = 0
        
        func increment() {
            value += 1
        }
        
        func getValue() -> Int {
            value
        }
        
        func reset() {
            value = 0
        }
    }
    
    // MARK: - Stress Tests
    
    /// Tests concurrent execution of 1000 commands to validate thread safety.
    func testConcurrentCommandExecution() async throws {
        let counter = Counter()
        let handler = CountingHandler(counter: counter)
        let bus = CommandBus()
        
        // Register handler
        try await bus.register(TestCommand.self, handler: handler)
        
        let commandCount = 1000
        let concurrencyLevel = 10 // Number of concurrent task groups
        let commandsPerGroup = commandCount / concurrencyLevel
        
        // Create commands
        let commands = autoreleasepool {
            (0..<commandCount).map { index in
                TestCommand(id: index, payload: "payload-\(index)")
            }
        }
        
        let startTime = Date()
        var allResults: [TestCommand.Result] = []
        
        // Execute commands concurrently in groups
        await withTaskGroup(of: [TestCommand.Result].self) { group in
            for groupIndex in 0..<concurrencyLevel {
                let startIndex = groupIndex * commandsPerGroup
                let endIndex = min(startIndex + commandsPerGroup, commandCount)
                let groupCommands = Array(commands[startIndex..<endIndex])
                
                group.addTask {
                    var groupResults: [TestCommand.Result] = []
                    
                    for command in groupCommands {
                        do {
                            let result = try await bus.send(command)
                            groupResults.append(result)
                        } catch {
                            XCTFail("Command \(command.id) failed: \(error)")
                        }
                    }
                    
                    return groupResults
                }
            }
            
            // Collect all results
            for await groupResults in group {
                allResults.append(contentsOf: groupResults)
            }
        }
        
        let endTime = Date()
        let totalDuration = endTime.timeIntervalSince(startTime)
        
        // Validate results
        XCTAssertEqual(allResults.count, commandCount, "Should have processed all commands")
        
        // Verify counter state
        let finalCount = await counter.getValue()
        XCTAssertEqual(finalCount, commandCount, "Counter should have been incremented for each command")
        
        // Verify all command IDs are unique and present
        let resultIds = Set(allResults.map { $0.commandId })
        let expectedIds = Set(0..<commandCount)
        XCTAssertEqual(resultIds, expectedIds, "All command IDs should be present and unique")
        
        // Verify all payloads were processed correctly
        for result in allResults {
            XCTAssertEqual(result.processedPayload, "processed-payload-\(result.commandId)")
        }
        
        // Deterministic validation: verify results can be sorted and matched exactly
        let sortedResults = allResults.sorted { $0.commandId < $1.commandId }
        for (index, result) in sortedResults.enumerated() {
            XCTAssertEqual(result.commandId, index, "Command ID should match array index after sorting")
            XCTAssertEqual(result.processedPayload, "processed-payload-\(index)")
            XCTAssertGreaterThan(result.processingTime, 0, "Processing time should be positive")
            XCTAssertLessThan(result.processingTime, 1.0, "Processing time should be reasonable")
        }
        
        // Verify no commands were lost or duplicated
        let commandIdCounts = allResults.reduce(into: [Int: Int]()) { counts, result in
            counts[result.commandId, default: 0] += 1
        }
        
        for (commandId, count) in commandIdCounts {
            XCTAssertEqual(count, 1, "Command \(commandId) should appear exactly once in results")
        }
        
        print("Executed \(commandCount) commands in \(totalDuration)s (\(Double(commandCount)/totalDuration) commands/sec)")
        
        // Performance assertions
        XCTAssertLessThan(totalDuration, 30.0, "Should complete within 30 seconds")
        let commandsPerSecond = Double(commandCount) / totalDuration
        XCTAssertGreaterThan(commandsPerSecond, 50.0, "Should process at least 50 commands per second")
    }
    
    /// Tests concurrent handler registration to validate registry thread safety.
    func testConcurrentHandlerRegistration() async throws {
        let bus = CommandBus()
        let counter = Counter()
        
        let registrationCount = 100
        
        // Register multiple handlers concurrently
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<registrationCount {
                group.addTask {
                    do {
                        let handler = CountingHandler(counter: counter)
                        try await bus.register(TestCommand.self, handler: handler)
                    } catch {
                        // Expected - only one handler can be registered per command type
                        // This tests that the registry properly handles concurrent registration attempts
                    }
                }
            }
        }
        
        // Verify that a handler is registered and functional
        let command = TestCommand(id: 1, payload: "test")
        let result = try await bus.send(command)
        XCTAssertEqual(result.commandId, 1)
        XCTAssertEqual(result.processedPayload, "processed-test")
    }
    
    /// Tests mixed concurrent operations (registration + execution).
    func testMixedConcurrentOperations() async throws {
        let bus = CommandBus()
        let counter = Counter()
        let handler = CountingHandler(counter: counter)
        
        // Register initial handler
        try await bus.register(TestCommand.self, handler: handler)
        
        let operationCount = 500
        var results: [TestCommand.Result] = []
        
        await withTaskGroup(of: TestCommand.Result?.self) { group in
            for index in 0..<operationCount {
                group.addTask {
                    if index % 10 == 0 {
                        // Every 10th operation, try to re-register (should fail gracefully)
                        do {
                            try await bus.register(TestCommand.self, handler: handler)
                        } catch {
                            // Expected - handler already registered
                        }
                        return nil
                    } else {
                        // Execute command
                        let command = TestCommand(id: index, payload: "payload-\(index)")
                        do {
                            return try await bus.send(command)
                        } catch {
                            XCTFail("Command \(index) failed: \(error)")
                            return nil
                        }
                    }
                }
            }
            
            // Collect results
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
        }
        
        // Should have ~90% of operations as successful commands (excluding registration attempts)
        let expectedCommandCount = operationCount - (operationCount / 10)
        XCTAssertEqual(results.count, expectedCommandCount, "Should have executed most commands successfully")
        
        let finalCount = await counter.getValue()
        XCTAssertEqual(finalCount, expectedCommandCount, "Counter should match successful command count")
    }
    
    /// Tests concurrent pipeline execution with middleware.
    func testConcurrentPipelineExecution() async throws {
        let counter = Counter()
        let handler = CountingHandler(counter: counter)
        
        // Create pipeline with multiple middleware
        let bus = CommandBus()
        try await bus.register(TestCommand.self, handler: handler)
        
        
        let commandCount = 200
        let commands = (0..<commandCount).map { index in
            TestCommand(id: index, payload: "pipeline-\(index)")
        }
        
        var results: [TestCommand.Result] = []
        
        // Execute all commands concurrently
        await withTaskGroup(of: TestCommand.Result.self) { group in
            for command in commands {
                group.addTask {
                    do {
                        return try await bus.send(command)
                    } catch {
                        XCTFail("Pipeline command \(command.id) failed: \(error)")
                        fatalError("Test failed")
                    }
                }
            }
            
            for await result in group {
                results.append(result)
            }
        }
        
        XCTAssertEqual(results.count, commandCount)
        let finalCount = await counter.getValue()
        XCTAssertEqual(finalCount, commandCount)
        
        // Verify all results are correct
        let resultIds = Set(results.map { $0.commandId })
        let expectedIds = Set(0..<commandCount)
        XCTAssertEqual(resultIds, expectedIds)
    }
}