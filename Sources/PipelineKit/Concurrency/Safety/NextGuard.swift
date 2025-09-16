import Foundation
import Atomics
import PipelineKitCore

/// A safety wrapper that ensures middleware `next` closures are called exactly once.
///
/// `NextGuard` prevents common middleware implementation errors:
/// - Multiple calls to `next()` 
/// - Concurrent calls to `next()`
/// - Forgetting to call `next()` (detected in debug builds)
///
/// The guard uses lock-free atomic operations for minimal performance overhead
/// while providing strong safety guarantees.
///
/// ## Implementation
///
/// Uses a state machine with three states:
/// - 0 (pending): Initial state, `next` has not been called
/// - 1 (executing): `next` is currently executing
/// - 2 (completed): `next` has completed execution
///
/// State transitions are atomic and irreversible:
/// ```
/// pending -> executing -> completed
/// ```
public final class NextGuard<T: Command>: Sendable {
    /// The wrapped next closure
    private let next: @Sendable (T, CommandContext) async throws -> T.Result
    
    /// Atomic state: 0=pending, 1=executing, 2=completed
    private let state = ManagedAtomic<Int>(0)
    
    /// Optional identifier for debugging
    private let identifier: String?
    
    /// Whether to suppress deinit warnings when `next` was never called
    private let suppressDeinitWarning: Bool
    
    /// Creates a new NextGuard wrapping the given next closure.
    ///
    /// - Parameters:
    ///   - next: The middleware next closure to guard
    ///   - identifier: Optional identifier for debugging
    ///   - suppressDeinitWarning: If true, suppresses the warning when guard is deallocated without being invoked
    public init(
        _ next: @escaping @Sendable (T, CommandContext) async throws -> T.Result,
        identifier: String? = nil,
        suppressDeinitWarning: Bool = false
    ) {
        self.next = next
        self.identifier = identifier
        self.suppressDeinitWarning = suppressDeinitWarning
    }
    
    /// Executes the guarded next closure, ensuring single execution.
    ///
    /// - Parameters:
    ///   - command: The command to pass to next
    ///   - context: The command context to pass to next
    /// - Returns: The result from the next closure
    /// - Throws: 
    ///   - `PipelineError.nextAlreadyCalled` if next was already called
    ///   - `PipelineError.nextCurrentlyExecuting` if next is currently executing
    ///   - Any error thrown by the next closure itself
    public func callAsFunction(
        _ command: T,
        _ context: CommandContext
    ) async throws -> T.Result {
        // Attempt atomic transition from pending (0) to executing (1)
        let (exchanged, original) = state.compareExchange(
            expected: 0,
            desired: 1,
            ordering: .relaxed
        )
        
        // Check if the exchange succeeded
        guard exchanged else {
            // Exchange failed - check why based on current state
            switch original {
            case 1:
                // Currently executing - concurrent call attempted
                throw PipelineError.nextCurrentlyExecuting
            case 2:
                // Already completed - multiple call attempted
                throw PipelineError.nextAlreadyCalled
            default:
                // Unexpected state (should never happen)
                assertionFailure("NextGuard in unexpected state: \(original)")
                throw PipelineError.nextAlreadyCalled
            }
        }
        
        // Ensure we transition to completed state even if cancelled or throwing
        defer {
            state.store(2, ordering: .relaxed)
        }
        
        // Execute the actual next closure
        return try await next(command, context)
    }
    
    /// Alternative call syntax for compatibility
    public func execute(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        try await self(command, context)
    }
    
    #if DEBUG
    /// Debug-only check that next was called before deallocation
    deinit {
        // Check if warnings are enabled
        guard NextGuardConfiguration.shared.emitWarnings else { return }
        
        let finalState = state.load(ordering: .relaxed)
        if finalState == 0 {
            // Check if task was cancelled
            if Task.isCancelled {
                return // Cancellation is acceptable
            }
            // Respect per-instance suppression
            if suppressDeinitWarning {
                return
            }
            
            let id = identifier ?? "unknown"
            let message = "⚠️ WARNING: NextGuard(\(id)) deallocated without calling next() - middleware must call next exactly once (unless cancelled)"
            
            // Use custom handler if provided, otherwise print
            if let handler = NextGuardConfiguration.shared.warningHandler {
                handler(message)
            } else {
                print(message)
            }
            
            #if false
            assertionFailure(
                "NextGuard(\(id)) deallocated without calling next() - " +
                "middleware must call next exactly once (unless cancelled)"
            )
            #endif
        }
    }
    #endif
}

// MARK: - Diagnostic Support

public extension NextGuard {
    /// Current state for diagnostics (debug builds only)
    var currentState: String {
        switch state.load(ordering: .relaxed) {
        case 0: return "pending"
        case 1: return "executing"
        case 2: return "completed"
        default: return "unknown"
        }
    }
    
    /// Whether next has been called
    var hasBeenCalled: Bool {
        state.load(ordering: .relaxed) > 0
    }
    
    /// Whether next has completed execution
    var hasCompleted: Bool {
        state.load(ordering: .relaxed) == 2
    }
}
