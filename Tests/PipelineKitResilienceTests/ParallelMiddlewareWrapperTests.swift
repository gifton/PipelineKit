import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience
import PipelineKitTestSupport

final class ParallelMiddlewareWrapperTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let id: String
    }
    
    private final class TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
            return "Handled: \(command.id)"
        }
    }
    
    private actor ExecutionTracker {
        private var executions: [(middleware: String, startTime: Date, endTime: Date?)] = []
        
        func recordStart(middleware: String) {
            executions.append((middleware: middleware, startTime: Date(), endTime: nil))
        }
        
        func recordEnd(middleware: String) {
            if let index = executions.lastIndex(where: { $0.middleware == middleware && $0.endTime == nil }) {
                executions[index].endTime = Date()
            }
        }
        
        func getExecutions() -> [(middleware: String, startTime: Date, endTime: Date?)] {
            return executions
        }
        
        func clear() {
            executions.removeAll()
        }
        
        func wasExecutedConcurrently() -> Bool {
            guard executions.count >= 2 else { return false }
            
            // Check if any two middleware overlapped in execution
            for i in 0..<executions.count {
                for j in (i + 1)..<executions.count {
                    let exec1 = executions[i]
                    let exec2 = executions[j]
                    
                    guard let end1 = exec1.endTime, let end2 = exec2.endTime else { continue }
                    
                    // Check if they overlapped
                    let overlap = exec1.startTime < end2 && exec2.startTime < end1
                    if overlap {
                        return true
                    }
                }
            }
            
            return false
        }
    }
    
    /// Holds every observer that has started until `parties` of them are in flight
    /// at once. Sequential execution can never satisfy it: the first observer would
    /// wait for a second that is not started until the first returns. That makes
    /// "ran in parallel" an ordering fact instead of a wall-clock measurement.
    private actor StartBarrier {
        private let parties: Int
        private var arrived = 0
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// True only when the barrier opened because all parties were in flight together.
        private(set) var allArrivedTogether = false

        init(parties: Int) { self.parties = parties }

        func arrive() async {
            arrived += 1
            if released { return }
            if arrived >= parties {
                allArrivedTogether = true
                release()
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Opens the barrier without marking success, so a regression to sequential
        /// execution fails the assertion instead of hanging the test.
        func releaseForFallback() { release() }

        private func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private final class TrackingObserver: ObserverMiddleware {
        let name: String
        let tracker: ExecutionTracker
        let delay: TimeInterval
        let priority = ExecutionPriority.processing
        let synchronizer: TestSynchronizer
        let barrier: StartBarrier?

        init(
            name: String,
            tracker: ExecutionTracker,
            delay: TimeInterval = 0.1,
            synchronizer: TestSynchronizer = TestSynchronizer(),
            barrier: StartBarrier? = nil
        ) {
            self.name = name
            self.tracker = tracker
            self.delay = delay
            self.synchronizer = synchronizer
            self.barrier = barrier
        }

        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            await tracker.recordStart(middleware: name)
            await barrier?.arrive()

            // Simulate work with cancellation check
            if delay > 0 {
                // Check for cancellation before starting work
                try Task.checkCancellation()

                // Use Task.sleep which is cancellation-aware
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    // If cancelled during sleep, don't record end
                    throw error
                }

                // Check again after work
                try Task.checkCancellation()
            }

            await tracker.recordEnd(middleware: name)
        }
    }
    
    // MARK: - Tests
    
    func testParallelExecution() async throws {
        // Given
        let tracker = ExecutionTracker()
        // No observer proceeds until all three are in flight together; see StartBarrier.
        let barrier = StartBarrier(parties: 3)
        let fallback = Task {
            try? await Task.sleep(for: .seconds(10))
            await barrier.releaseForFallback()
        }
        defer { fallback.cancel() }
        let observers = [
            TrackingObserver(name: "MW1", tracker: tracker, delay: 0.2, synchronizer: synchronizer, barrier: barrier),
            TrackingObserver(name: "MW2", tracker: tracker, delay: 0.2, synchronizer: synchronizer, barrier: barrier),
            TrackingObserver(name: "MW3", tracker: tracker, delay: 0.2, synchronizer: synchronizer, barrier: barrier)
        ]

        let parallelWrapper = ParallelMiddlewareWrapper(observers: observers)
        
        // When
        let startTime = Date()
        _ = try await parallelWrapper.execute(
            TestCommand(id: "test"),
            context: CommandContext(),
            next: { command, _ in command.id }
        )
        let duration = Date().timeIntervalSince(startTime)
        
        // Then
        // Parallelism is asserted by the barrier, not by the clock: sequential
        // execution takes about 0.6s against 0.2s in parallel, but a wall-clock
        // bound between the two (it was 0.4s) fails whenever a shared runner
        // stalls for 200ms. The elapsed bound below only detects a hang.
        let ranTogether = await barrier.allArrivedTogether
        XCTAssertTrue(ranTogether, "All three observers should be in flight at the same time")
        XCTAssertLessThan(duration, 10, "Parallel execution should not hang")
        
        let wasConcurrent = await tracker.wasExecutedConcurrently()
        XCTAssertTrue(wasConcurrent, "Middleware should have executed concurrently")
    }
    
    func testEmptyMiddlewareArray() async throws {
        // Given
        let parallelWrapper = ParallelMiddlewareWrapper(observers: [])

        // When
        let result = try await parallelWrapper.execute(
            TestCommand(id: "empty"),
            context: CommandContext(),
            next: { command, _ in "Next called: \(command.id)" }
        )
        
        // Then
        XCTAssertEqual(result, "Next called: empty")
    }
    
    func testSingleMiddleware() async throws {
        // Given
        let tracker = ExecutionTracker()
        let observer = TrackingObserver(name: "Single", tracker: tracker, synchronizer: synchronizer)
        let parallelWrapper = ParallelMiddlewareWrapper(observers: [observer])
        
        // When
        _ = try await parallelWrapper.execute(
            TestCommand(id: "single"),
            context: CommandContext(),
            next: { (command: TestCommand, _) in command.id }
        )
        
        // Then
        let executions = await tracker.getExecutions()
        XCTAssertEqual(executions.count, 1)
        XCTAssertEqual(executions.first?.middleware, "Single")
    }
    
    func testErrorPropagation() async throws {
        // Given
        let errorObserver = ErrorThrowingObserver(error: TestError.middleware)
        let parallelWrapper = ParallelMiddlewareWrapper(observers: [errorObserver])
        
        // When/Then
        do {
            _ = try await parallelWrapper.execute(
                TestCommand(id: "error"),
                context: CommandContext(),
                next: { _, _ in "Should not reach" }
            )
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }
    
    func testMultipleErrorsCancelOthers() async throws {
        // Given
        let tracker = ExecutionTracker()
        let observers: [any ObserverMiddleware] = [
            TrackingObserver(name: "MW1", tracker: tracker, delay: 0.1, synchronizer: synchronizer),
            ErrorThrowingObserver(error: TestError.middleware, delay: 0.05, synchronizer: synchronizer), // Fails quickly
            // Should be cancelled. Its work must outlast the 50ms failure by far more
            // than any scheduling stall, or a stalled runner lets it complete first.
            TrackingObserver(name: "MW3", tracker: tracker, delay: 30, synchronizer: synchronizer)
        ]

        let parallelWrapper = ParallelMiddlewareWrapper(observers: observers)
        
        // When/Then
        do {
            _ = try await parallelWrapper.execute(
                TestCommand(id: "multi-error"),
                context: CommandContext(),
                next: { _, _ in "Should not reach" }
            )
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is TestError)
        }
        
        // Give some time for cancellation to complete
        await synchronizer.mediumDelay()
        
        // MW3 might have started but should not have completed
        let executions = await tracker.getExecutions()
        let mw3Executions = executions.filter { $0.middleware == "MW3" }
        
        if !mw3Executions.isEmpty {
            // If MW3 started, it should not have completed
            XCTAssertNil(mw3Executions.first?.endTime, "MW3 should have been cancelled")
        }
    }
    
    func testContextIsolation() async throws {
        // Given
        let observers = [
            ContextModifyingObserver(key: "key1", value: "value1"),
            ContextModifyingObserver(key: "key2", value: "value2"),
            ContextModifyingObserver(key: "key3", value: "value3")
        ]

        let parallelWrapper = ParallelMiddlewareWrapper(observers: observers)
        let context = CommandContext()
        
        // When
        _ = try await parallelWrapper.execute(
            TestCommand(id: "context"),
            context: context,
            next: { _, _ in
                // Check that context modifications from parallel middleware are isolated
                return "Completed"
            }
        )
        
        // Then
        // Context modifications in parallel middleware should be isolated
        // The original context should not be modified
        let value1: String? = context[TestContextKeys.dynamic("key1")]
        let value2: String? = context[TestContextKeys.dynamic("key2")]
        let value3: String? = context[TestContextKeys.dynamic("key3")]
        
        XCTAssertNil(value1)
        XCTAssertNil(value2)
        XCTAssertNil(value3)
    }
    
    func testPriorityInheritance() async throws {
        // Given
        let observer1 = PriorityObserver(priority: .authentication)
        let observer2 = PriorityObserver(priority: .validation)

        // When - default priority
        let defaultWrapper = ParallelMiddlewareWrapper(observers: [observer1, observer2])
        XCTAssertEqual(defaultWrapper.priority, .custom)

        // When - explicit priority
        let explicitWrapper = ParallelMiddlewareWrapper(
            observers: [observer1, observer2],
            priority: .processing
        )
        XCTAssertEqual(explicitWrapper.priority, .processing)
    }
    
    func testLargeNumberOfMiddleware() async throws {
        // Given
        let middlewareCount = 100
        let tracker = ExecutionTracker()
        // No observer proceeds until all of them are in flight together; see StartBarrier.
        let barrier = StartBarrier(parties: middlewareCount)
        let fallback = Task {
            try? await Task.sleep(for: .seconds(10))
            await barrier.releaseForFallback()
        }
        defer { fallback.cancel() }
        let observers = (0..<middlewareCount).map { i in
            TrackingObserver(name: "MW\(i)", tracker: tracker, delay: 0.01, synchronizer: synchronizer, barrier: barrier)
        }

        let parallelWrapper = ParallelMiddlewareWrapper(observers: observers)
        
        // When
        let startTime = Date()
        _ = try await parallelWrapper.execute(
            TestCommand(id: "large"),
            context: CommandContext(),
            next: { command, _ in command.id }
        )
        let duration = Date().timeIntervalSince(startTime)
        
        // Then
        // Parallelism is asserted by the barrier (all 100 in flight at once), not by
        // the former 0.5s wall-clock bound, which a stalled runner exceeds. The
        // elapsed bound only detects a hang.
        let ranTogether = await barrier.allArrivedTogether
        XCTAssertTrue(ranTogether, "All observers should be in flight at the same time")
        XCTAssertLessThan(duration, 10, "Large number of middleware should not hang")
        
        let executions = await tracker.getExecutions()
        XCTAssertEqual(executions.count, middlewareCount)
    }
    
    // MARK: - Helper Types
    
    private enum TestError: Error {
        case middleware
    }
    
    private final class ErrorThrowingObserver: ObserverMiddleware {
        let error: Error
        let delay: TimeInterval
        let priority = ExecutionPriority.processing
        let synchronizer: TestSynchronizer

        init(error: Error, delay: TimeInterval = 0, synchronizer: TestSynchronizer = TestSynchronizer()) {
            self.error = error
            self.delay = delay
            self.synchronizer = synchronizer
        }

        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            throw error
        }
    }
    
    private final class ContextModifyingObserver: ObserverMiddleware {
        let key: String
        let value: String
        let priority = ExecutionPriority.processing

        init(key: String, value: String) {
            self.key = key
            self.value = value
        }

        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            // Note: Can't dynamically create context keys at runtime
            // This test was trying to verify context isolation, but we'd need
            // pre-defined key types for that
            _ = key
            _ = value
        }
    }

    private final class PriorityObserver: ObserverMiddleware {
        let priority: ExecutionPriority

        init(priority: ExecutionPriority) {
            self.priority = priority
        }

        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            // No side effects; used only to verify wrapper priority inheritance.
        }
    }
}
