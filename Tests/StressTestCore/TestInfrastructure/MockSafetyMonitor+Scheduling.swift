import Foundation
@testable import PipelineKit

/// Protocol for scheduling safety violations in tests.
///
/// ViolationScheduler enables deterministic testing of safety violation scenarios
/// by allowing tests to schedule violations at specific times or conditions.
public protocol ViolationScheduler: Sendable {
    /// Schedules a violation to occur based on the specified trigger.
    /// - Parameter violation: The violation to schedule.
    /// - Returns: The unique identifier for tracking this scheduled violation.
    @discardableResult
    func schedule(_ violation: ScheduledViolation) async -> UUID
    
    /// Cancels a scheduled violation.
    /// - Parameter id: The identifier of the violation to cancel.
    /// - Returns: True if the violation was cancelled, false if not found or already triggered.
    @discardableResult
    func cancel(_ id: UUID) async -> Bool
    
    /// Cancels all pending violations.
    func cancelAll() async
    
    /// Returns the history of all triggered violations.
    /// - Returns: Array of violation records in chronological order.
    func history() async -> [ViolationRecord]
    
    /// Returns all currently pending violations.
    /// - Returns: Array of scheduled violations that haven't triggered yet.
    func pendingViolations() async -> [ScheduledViolation]
}

// MARK: - Violation Severity

/// Severity levels for safety violations.
public enum ViolationSeverity: Int, Sendable, Comparable, CaseIterable {
    /// Minor violation for testing warning systems.
    case warning = 1
    
    /// Moderate violation for standard test scenarios.
    case moderate = 2
    
    /// Critical violation that should trigger safety mechanisms.
    case critical = 3
    
    /// Emergency violation requiring immediate shutdown.
    case emergency = 4
    
    public static func < (lhs: ViolationSeverity, rhs: ViolationSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    /// Human-readable description of the severity.
    public var description: String {
        switch self {
        case .warning: return "Warning"
        case .moderate: return "Moderate"
        case .critical: return "Critical"
        case .emergency: return "Emergency"
        }
    }
}

// MARK: - Violation Triggers

/// Defines when a violation should be triggered.
public enum ViolationTrigger: Sendable {
    /// Trigger after a specified time delay.
    case afterDelay(TimeInterval)
    
    /// Trigger at a specific time.
    case atTime(Date)
    
    /// Trigger when a condition becomes true.
    case whenCondition(@Sendable () async -> Bool)
    
    /// Trigger based on a resource usage pattern.
    case pattern(ViolationPattern, duration: TimeInterval)
    
    /// Human-readable description of the trigger.
    public var description: String {
        switch self {
        case .afterDelay(let delay):
            return "After \(delay)s"
        case .atTime(let date):
            return "At \(date)"
        case .whenCondition:
            return "When condition met"
        case .pattern(let pattern, let duration):
            return "\(pattern.description) over \(duration)s"
        }
    }
}

// MARK: - Violation Patterns

/// Patterns for simulating resource usage violations.
public enum ViolationPattern: Sendable {
    /// Gradually increase from start to end value.
    case gradual(start: Double, end: Double)
    
    /// Spike from baseline to peak at specified time.
    case spike(baseline: Double, peak: Double, at: TimeInterval)
    
    /// Oscillate between min and max values.
    case oscillating(min: Double, max: Double, period: TimeInterval)
    
    /// Random values within range, changing at intervals.
    case random(range: ClosedRange<Double>, changeInterval: TimeInterval)
    
    /// Step through specified levels.
    case stepped(levels: [(value: Double, duration: TimeInterval)])
    
    /// Human-readable description of the pattern.
    public var description: String {
        switch self {
        case .gradual(let start, let end):
            return "Gradual \(start) → \(end)"
        case .spike(let baseline, let peak, let at):
            return "Spike \(baseline) → \(peak) at \(at)s"
        case .oscillating(let min, let max, let period):
            return "Oscillating \(min) ↔ \(max) period:\(period)s"
        case .random(let range, let interval):
            return "Random \(range) interval:\(interval)s"
        case .stepped(let levels):
            return "Stepped through \(levels.count) levels"
        }
    }
}

// MARK: - Scheduled Violation

/// Represents a violation that has been scheduled but not yet triggered.
public struct ScheduledViolation: Sendable, Identifiable {
    /// Unique identifier for this scheduled violation.
    public let id: UUID
    
    /// The trigger condition for this violation.
    public let trigger: ViolationTrigger
    
    /// The type of violation (memory, CPU, etc.).
    public let type: TestDefaults.ViolationType
    
    /// The severity of the violation.
    public let severity: ViolationSeverity
    
    /// Additional metadata about the violation.
    public let metadata: [String: String]
    
    /// When this violation was scheduled.
    public let scheduledAt: Date
    
    /// Whether this violation is still active (not cancelled or triggered).
    public var isActive: Bool
    
    public init(
        id: UUID = UUID(),
        trigger: ViolationTrigger,
        type: TestDefaults.ViolationType,
        severity: ViolationSeverity,
        metadata: [String: String] = [:],
        scheduledAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.trigger = trigger
        self.type = type
        self.severity = severity
        self.metadata = metadata
        self.scheduledAt = scheduledAt
        self.isActive = isActive
    }
}

// MARK: - Violation Record

/// Historical record of a triggered violation.
public struct ViolationRecord: Sendable, Identifiable {
    /// Unique identifier for this record.
    public let id: UUID
    
    /// The ID of the scheduled violation that triggered this (if any).
    public let scheduledViolationId: UUID?
    
    /// The type of violation.
    public let type: TestDefaults.ViolationType
    
    /// The severity of the violation.
    public let severity: ViolationSeverity
    
    /// When the violation was triggered.
    public let triggeredAt: Date
    
    /// When the violation was resolved (if applicable).
    public var resolvedAt: Date?
    
    /// What triggered this violation (e.g., "Scheduled", "Manual", "System").
    public let triggerSource: String
    
    /// Additional metadata about the violation.
    public let metadata: [String: String]
    
    /// Stack trace at the time of violation (for debugging).
    public let stackTrace: [String]?
    
    public init(
        id: UUID = UUID(),
        scheduledViolationId: UUID? = nil,
        type: TestDefaults.ViolationType,
        severity: ViolationSeverity,
        triggeredAt: Date = Date(),
        resolvedAt: Date? = nil,
        triggerSource: String,
        metadata: [String: String] = [:],
        stackTrace: [String]? = nil
    ) {
        self.id = id
        self.scheduledViolationId = scheduledViolationId
        self.type = type
        self.severity = severity
        self.triggeredAt = triggeredAt
        self.resolvedAt = resolvedAt
        self.triggerSource = triggerSource
        self.metadata = metadata
        self.stackTrace = stackTrace
    }
    
    /// Duration of the violation (nil if not yet resolved).
    public var duration: TimeInterval? {
        guard let resolvedAt = resolvedAt else { return nil }
        return resolvedAt.timeIntervalSince(triggeredAt)
    }
}

// MARK: - MockSafetyMonitor Extension Placeholder

// Note: The actual implementation of ViolationScheduler for MockSafetyMonitor
// will be added in the next phase. This extension serves as a placeholder
// to indicate where the implementation will go.

/*
extension MockSafetyMonitor: ViolationScheduler {
    // Implementation will be added in Phase A, Step 2
}
*/