import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience

final class DetailedTimeoutTest: XCTestCase {
    // Test command
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
        
        func execute() async throws -> String {
            return value
        }
    }
    
    // Test handler
    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            print("    [Handler] Executed")
            return command.value
        }
    }
    
    // Custom timeout middleware with debug output
    private struct DebugTimeoutMiddleware: Middleware {
        let timeout: TimeInterval
        let priority: ExecutionPriority = .resilience
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            print("  [TimeoutMiddleware] Starting with \(timeout)s timeout")
            let start = Date()
            
            do {
                // Directly use withTimeout to debug
                let result = try await withTimeout(timeout) {
                    print("    [TimeoutMiddleware] Calling next...")
                    let r = try await next(command, context)
                    print("    [TimeoutMiddleware] Next completed")
                    return r
                }
                
                let elapsed = Date().timeIntervalSince(start)
                print("  [TimeoutMiddleware] Completed in \(elapsed)s")
                return result
            } catch let error as TimeoutError {
                let elapsed = Date().timeIntervalSince(start)
                print("  [TimeoutMiddleware] Timed out after \(elapsed)s")
                throw PipelineError.timeout(duration: timeout, context: nil)
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                print("  [TimeoutMiddleware] Error after \(elapsed)s: \(error)")
                throw error
            }
        }
        
        private func withTimeout<T: Sendable>(
            _ seconds: TimeInterval,
            operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            try await withThrowingTaskGroup(of: TimeoutRaceResult<T>.self) { group in
                // Add the main operation task
                group.addTask {
                    print("      [Timeout] Operation task started")
                    do {
                        let result = try await operation()
                        print("      [Timeout] Operation completed")
                        return .success(result)
                    } catch {
                        print("      [Timeout] Operation failed: \(error)")
                        return .failure(error)
                    }
                }
                
                // Add the timeout task
                group.addTask {
                    print("      [Timeout] Timer started (\(seconds)s)")
                    do {
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        print("      [Timeout] Timer expired!")
                        return .timeout
                    } catch {
                        print("      [Timeout] Timer cancelled")
                        return .cancelled
                    }
                }
                
                // Wait for the first result
                guard let firstResult = try await group.next() else {
                    throw TimeoutError.noResult
                }
                
                print("      [Timeout] First result: \(firstResult)")
                
                // Cancel all remaining tasks
                group.cancelAll()
                
                // Handle the result
                switch firstResult {
                case .success(let value):
                    return value
                case .timeout:
                    throw TimeoutError.exceeded(duration: seconds)
                case .failure(let error):
                    throw error
                case .cancelled:
                    if let secondResult = try await group.next() {
                        switch secondResult {
                        case .success(let value):
                            return value
                        case .timeout:
                            throw TimeoutError.exceeded(duration: seconds)
                        case .failure(let error):
                            throw error
                        case .cancelled:
                            throw CancellationError()
                        }
                    }
                    throw CancellationError()
                }
            }
        }
        
        private enum TimeoutRaceResult<T: Sendable>: Sendable {
            case success(T)
            case timeout
            case failure(Error)
            case cancelled
        }
    }
    
    // Slow middleware
    private struct SlowMiddleware: Middleware {
        let delay: TimeInterval
        let priority: ExecutionPriority = .postProcessing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            print("    [SlowMiddleware] Starting \(delay)s delay...")
            let start = Date()
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let elapsed = Date().timeIntervalSince(start)
                print("    [SlowMiddleware] Completed after \(elapsed)s, calling next")
                return try await next(command, context)
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                print("    [SlowMiddleware] Interrupted after \(elapsed)s: \(error)")
                throw error
            }
        }
    }
    
    func testDetailedTimeout() async throws {
        print("\n=== Detailed Timeout Test ===")
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let timeoutMiddleware = DebugTimeoutMiddleware(timeout: 0.1)
        let slowMiddleware = SlowMiddleware(delay: 0.2)
        
        try await pipeline.addMiddleware(timeoutMiddleware)
        try await pipeline.addMiddleware(slowMiddleware)
        
        print("\nExecuting pipeline...")
        let command = TestCommand(value: "test")
        let context = CommandContext()
        let start = Date()
        
        do {
            let result = try await pipeline.execute(command, context: context)
            let elapsed = Date().timeIntervalSince(start)
            XCTFail("Should have timed out! Got: \(result) after \(elapsed)s")
        } catch let error as PipelineError {
            let elapsed = Date().timeIntervalSince(start)
            if case .timeout = error {
                print("\n✅ SUCCESS: Timed out after \(elapsed)s")
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }
}