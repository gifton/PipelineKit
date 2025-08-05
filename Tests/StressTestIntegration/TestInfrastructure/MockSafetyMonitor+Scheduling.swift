import Foundation
@testable import PipelineKit
@testable import StressTestSupport

// MARK: - Error Types

/// Errors that can occur during violation scheduling.
public enum ViolationSchedulingError: LocalizedError {
    case invalidDuration(TimeInterval)
    case invalidRange(String)
    case invalidPattern(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidDuration(let duration):
            return "Invalid duration: \(duration). Duration must be positive."
        case .invalidRange(let description):
            return "Invalid range: \(description)"
        case .invalidPattern(let description):
            return "Invalid pattern: \(description)"
        }
    }
}

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
public enum ViolationSeverity: Int, Sendable, Comparable, Equatable, CaseIterable {
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
public enum ViolationTrigger: Sendable, Equatable {
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
    
    public static func == (lhs: ViolationTrigger, rhs: ViolationTrigger) -> Bool {
        switch (lhs, rhs) {
        case (.afterDelay(let l), .afterDelay(let r)):
            return l == r
        case (.atTime(let l), .atTime(let r)):
            return l == r
        case (.whenCondition, .whenCondition):
            // Closures can't be compared, so we consider all conditions different
            return false
        case (.pattern(let lp, let ld), .pattern(let rp, let rd)):
            return lp == rp && ld == rd
        default:
            return false
        }
    }
}

// MARK: - Violation Patterns

/// Patterns for simulating resource usage violations.
public enum ViolationPattern: Sendable, Equatable {
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
    
    public static func == (lhs: ViolationPattern, rhs: ViolationPattern) -> Bool {
        switch (lhs, rhs) {
        case (.gradual(let ls, let le), .gradual(let rs, let re)):
            return ls == rs && le == re
        case (.spike(let lb, let lp, let lat), .spike(let rb, let rp, let rat)):
            return lb == rb && lp == rp && lat == rat
        case (.oscillating(let lmin, let lmax, let lperiod), .oscillating(let rmin, let rmax, let rperiod)):
            return lmin == rmin && lmax == rmax && lperiod == rperiod
        case (.random(let lrange, let linterval), .random(let rrange, let rinterval)):
            return lrange == rrange && linterval == rinterval
        case (.stepped(let llevels), .stepped(let rlevels)):
            return llevels.count == rlevels.count &&
                   llevels.enumerated().allSatisfy { index, level in
                       rlevels[index].value == level.value &&
                       rlevels[index].duration == level.duration
                   }
        default:
            return false
        }
    }
    
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
    
    /// Validates the pattern parameters.
    /// - Throws: ViolationSchedulingError if parameters are invalid.
    public func validate() throws {
        switch self {
        case .gradual(let start, let end):
            if start < 0 || end < 0 {
                throw ViolationSchedulingError.invalidRange("Start (\(start)) and end (\(end)) must be non-negative")
            }
        case .spike(let baseline, let peak, let at):
            if baseline < 0 || peak < 0 {
                throw ViolationSchedulingError.invalidRange("Baseline (\(baseline)) and peak (\(peak)) must be non-negative")
            }
            if at < 0 {
                throw ViolationSchedulingError.invalidDuration(at)
            }
        case .oscillating(let min, let max, let period):
            if min < 0 || max < 0 {
                throw ViolationSchedulingError.invalidRange("Min (\(min)) and max (\(max)) must be non-negative")
            }
            if min > max {
                throw ViolationSchedulingError.invalidRange("Min (\(min)) must be <= max (\(max))")
            }
            if period <= 0 {
                throw ViolationSchedulingError.invalidDuration(period)
            }
        case .random(let range, let interval):
            if range.lowerBound < 0 {
                throw ViolationSchedulingError.invalidRange("Range must have non-negative bounds")
            }
            if interval <= 0 {
                throw ViolationSchedulingError.invalidDuration(interval)
            }
        case .stepped(let levels):
            if levels.isEmpty {
                throw ViolationSchedulingError.invalidPattern("Stepped pattern must have at least one level")
            }
            for (index, level) in levels.enumerated() {
                if level.value < 0 {
                    throw ViolationSchedulingError.invalidRange("Level \(index) value (\(level.value)) must be non-negative")
                }
                if level.duration <= 0 {
                    throw ViolationSchedulingError.invalidDuration(level.duration)
                }
            }
        }
    }
}

// MARK: - Scheduled Violation

/// Represents a violation that has been scheduled but not yet triggered.
public struct ScheduledViolation: Sendable, Identifiable, Equatable {
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
    
    public static func == (lhs: ScheduledViolation, rhs: ScheduledViolation) -> Bool {
        // Compare all properties except isActive which can change
        lhs.id == rhs.id &&
        lhs.trigger == rhs.trigger &&
        lhs.type == rhs.type &&
        lhs.severity == rhs.severity &&
        lhs.metadata == rhs.metadata &&
        lhs.scheduledAt == rhs.scheduledAt
    }
}

// MARK: - Violation Record

/// Historical record of a triggered violation.
public struct ViolationRecord: Sendable, Identifiable, Equatable {
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

// MARK: - Factory Methods

public extension ScheduledViolation {
    /// Creates a memory spike violation scheduled after a delay.
    /// - Parameters:
    ///   - delay: Time to wait before triggering the spike.
    ///   - severity: The severity level (defaults to critical).
    /// - Returns: A configured scheduled violation.
    static func memorySpike(
        after delay: TimeInterval,
        severity: ViolationSeverity = .critical
    ) -> ScheduledViolation {
        ScheduledViolation(
            trigger: .afterDelay(delay),
            type: .memory,
            severity: severity,
            metadata: ["pattern": "spike", "trigger": "delayed"]
        )
    }
    
    /// Creates a CPU stress violation with a specified pattern.
    /// - Parameters:
    ///   - pattern: The CPU usage pattern to simulate.
    ///   - duration: How long to run the pattern.
    ///   - severity: The severity level (defaults to moderate).
    /// - Returns: A configured scheduled violation.
    static func cpuStress(
        pattern: ViolationPattern,
        duration: TimeInterval,
        severity: ViolationSeverity = .moderate
    ) -> ScheduledViolation {
        ScheduledViolation(
            trigger: .pattern(pattern, duration: duration),
            type: .cpu,
            severity: severity,
            metadata: ["pattern": pattern.description]
        )
    }
    
    /// Creates a critical failure scheduled at a specific time.
    /// - Parameters:
    ///   - type: The type of violation.
    ///   - time: When to trigger the violation.
    /// - Returns: A configured scheduled violation.
    static func criticalFailure(
        type: TestDefaults.ViolationType,
        at time: Date
    ) -> ScheduledViolation {
        ScheduledViolation(
            trigger: .atTime(time),
            type: type,
            severity: .emergency,
            metadata: ["failure": "critical", "scheduled": ISO8601DateFormatter().string(from: time)]
        )
    }
    
    /// Creates a gradual resource exhaustion pattern.
    /// - Parameters:
    ///   - type: The resource type to exhaust.
    ///   - start: Starting usage percentage (0.0-1.0).
    ///   - end: Ending usage percentage (0.0-1.0).
    ///   - duration: Time to transition from start to end.
    /// - Returns: A configured scheduled violation.
    static func gradualExhaustion(
        type: TestDefaults.ViolationType,
        from start: Double = 0.3,
        to end: Double = 0.95,
        over duration: TimeInterval
    ) -> ScheduledViolation {
        ScheduledViolation(
            trigger: .pattern(.gradual(start: start, end: end), duration: duration),
            type: type,
            severity: .critical,
            metadata: ["exhaustion": "gradual", "start": "\(start)", "end": "\(end)"]
        )
    }
}

// MARK: - MockSafetyMonitor Extension

// Note: The ViolationScheduler protocol implementation for MockSafetyMonitor
// has been completed in MockSafetyMonitor.swift. This file contains the
// protocol definitions and supporting types used by the implementation.
