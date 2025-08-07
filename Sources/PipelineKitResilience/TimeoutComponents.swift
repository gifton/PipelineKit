import Foundation
import PipelineKitCore

// MARK: - Grace Period Manager

/// Manages grace periods with cancellation support
actor GracePeriodManager {
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    
    /// Starts a grace period that can be cancelled
    func startGracePeriod(
        duration: TimeInterval,
        onExpiration: @escaping @Sendable () async -> Void
    ) -> UUID {
        let id = UUID()
        
        let task = Task {
            // Use multiple shorter sleeps for cancellation responsiveness
            let intervals = 10
            let intervalDuration = duration / Double(intervals)
            
            for _ in 0..<intervals {
                guard !Task.isCancelled else { return }
                
                do {
                    try await Task.sleep(nanoseconds: UInt64(intervalDuration * 1_000_000_000))
                } catch {
                    // Cancelled during sleep
                    return
                }
            }
            
            // Grace period expired
            if !Task.isCancelled {
                await onExpiration()
            }
        }
        
        activeTasks[id] = task
        return id
    }
    
    /// Cancels a grace period
    func cancelGracePeriod(_ id: UUID) {
        if let task = activeTasks[id] {
            task.cancel()
            activeTasks.removeValue(forKey: id)
        }
    }
    
    /// Cancels all active grace periods
    func cancelAll() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
    }
}

// MARK: - Timeout Context

/// Rich context for timeout errors
public struct TimeoutContext: Sendable {
    /// The command that timed out
    public let commandType: String
    
    /// The timeout duration that was exceeded
    public let timeoutDuration: TimeInterval
    
    /// How long the command actually ran before timeout
    public let actualDuration: TimeInterval
    
    /// Grace period configuration
    public let gracePeriod: TimeInterval
    
    /// Whether grace period was used
    public let gracePeriodUsed: Bool
    
    /// Timeout reason
    public let reason: TimeoutReason
    
    /// Additional metadata
    public let metadata: [String: String]
    
    public init(
        commandType: String,
        timeoutDuration: TimeInterval,
        actualDuration: TimeInterval,
        gracePeriod: TimeInterval,
        gracePeriodUsed: Bool,
        reason: TimeoutReason,
        metadata: [String: String] = [:]
    ) {
        self.commandType = commandType
        self.timeoutDuration = timeoutDuration
        self.actualDuration = actualDuration
        self.gracePeriod = gracePeriod
        self.gracePeriodUsed = gracePeriodUsed
        self.reason = reason
        self.metadata = metadata
    }
}

/// Reasons for timeout
public enum TimeoutReason: String, Sendable {
    case executionTimeout = "execution_timeout"
    case gracePeriodExpired = "grace_period_expired"
    case taskCancelled = "task_cancelled"
    case customTimeout = "custom_timeout"
}

// MARK: - Enhanced Timeout Error

/// Enhanced pipeline error with timeout context
public extension PipelineError {
    static func timeoutWithContext(_ context: TimeoutContext) -> PipelineError {
        let errorContext = ErrorContext(
            commandType: context.commandType,
            middlewareType: "TimeoutMiddleware",
            additionalInfo: [
                "timeout_duration": String(context.timeoutDuration),
                "actual_duration": String(context.actualDuration),
                "grace_period": String(context.gracePeriod),
                "grace_period_used": String(context.gracePeriodUsed),
                "reason": context.reason.rawValue
            ].merging(context.metadata) { _, new in new }
        )
        
        return .timeout(duration: context.timeoutDuration, context: errorContext)
    }
}

// MARK: - Progressive Backoff

/// Configuration for progressive grace period backoff
public struct GracePeriodBackoff: Sendable {
    public let initialDuration: TimeInterval
    public let maxDuration: TimeInterval
    public let multiplier: Double
    public let jitter: Double
    
    public init(
        initialDuration: TimeInterval = 0.5,
        maxDuration: TimeInterval = 5.0,
        multiplier: Double = 1.5,
        jitter: Double = 0.1
    ) {
        self.initialDuration = initialDuration
        self.maxDuration = maxDuration
        self.multiplier = multiplier
        self.jitter = jitter
    }
    
    /// Calculate next backoff duration
    public func nextDuration(attemptNumber: Int) -> TimeInterval {
        let baseDelay = initialDuration * pow(multiplier, Double(attemptNumber - 1))
        let clampedDelay = min(baseDelay, maxDuration)
        
        // Add jitter
        let jitterRange = clampedDelay * jitter
        let randomJitter = Double.random(in: -jitterRange...jitterRange)
        
        return max(0, clampedDelay + randomJitter)
    }
}

// MARK: - Timeout State Tracker

/// Tracks timeout state for better edge case handling
actor TimeoutStateTracker {
    enum State: Sendable {
        case idle
        case executing
        case timedOut
        case gracePeriod
        case completed
        case cancelled
    }
    
    private var state: State = .idle
    private var stateTimestamps: [State: Date] = [:]
    
    func transition(to newState: State) -> Bool {
        // Validate state transition
        let isValid = isValidTransition(from: state, to: newState)
        if isValid {
            state = newState
            stateTimestamps[newState] = Date()
        }
        return isValid
    }
    
    func currentState() -> State {
        return state
    }
    
    func stateHistory() -> [(State, Date)] {
        return stateTimestamps
            .sorted { $0.value < $1.value }
            .map { ($0.key, $0.value) }
    }
    
    private func isValidTransition(from: State, to: State) -> Bool {
        switch (from, to) {
        case (.idle, .executing),
             (.executing, .timedOut),
             (.executing, .completed),
             (.executing, .cancelled),
             (.timedOut, .gracePeriod),
             (.timedOut, .cancelled),
             (.gracePeriod, .completed),
             (.gracePeriod, .cancelled):
            return true
        default:
            return false
        }
    }
}