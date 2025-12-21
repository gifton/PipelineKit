import Foundation
import PipelineKitCore

// Instrumented version of TimeoutMiddleware for debugging
// Conforms to NextGuardWarningSuppressing because it may cancel the wrapped
// operation before next() completes, which is expected behavior.
public struct InstrumentedTimeoutMiddleware: Middleware, NextGuardWarningSuppressing {
    public let priority: ExecutionPriority = .resilience
    private let timeout: TimeInterval
    
    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        print("  [InstrumentedTimeout] execute() called with \(timeout)s timeout")
        print("  [InstrumentedTimeout] Command type: \(type(of: command))")
        
        let start = Date()
        
        do {
            print("  [InstrumentedTimeout] Calling next with timeout...")
            let result = try await withTimeout(timeout) {
                print("    [InstrumentedTimeout-Operation] Calling next...")
                let r = try await next(command, context)
                print("    [InstrumentedTimeout-Operation] Next returned")
                return r
            }
            
            let elapsed = Date().timeIntervalSince(start)
            print("  [InstrumentedTimeout] Completed successfully after \(elapsed)s")
            return result
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("  [InstrumentedTimeout] Failed after \(elapsed)s: \(error)")
            
            if error is TimeoutError {
                throw PipelineError.timeout(duration: timeout, context: nil)
            }
            throw error
        }
    }
    
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: TimeoutRaceResult<T>.self) { group in
            group.addTask {
                do {
                    let result = try await operation()
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }
            
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    return .timeout
                } catch {
                    return .cancelled
                }
            }
            
            guard let firstResult = try await group.next() else {
                throw TimeoutError.noResult
            }
            
            group.cancelAll()
            
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
    
    private enum TimeoutError: Error {
        case exceeded(duration: TimeInterval)
        case noResult
    }
}
