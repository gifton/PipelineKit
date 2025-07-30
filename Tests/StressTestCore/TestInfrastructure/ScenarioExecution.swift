import Foundation
@testable import PipelineKit

/// Results from executing a test scenario.
///
/// ScenarioExecution captures comprehensive information about a test run including
/// timing, performance metrics, violations, leaks, and custom data.
public struct ScenarioExecution: Sendable {
    
    // MARK: - Properties
    
    /// Name of the executed scenario
    public let scenario: String
    
    /// When execution started
    public let startTime: Date
    
    /// When execution ended
    public let endTime: Date
    
    /// Total execution duration
    public let duration: TimeInterval
    
    /// Performance metrics collected
    public let metrics: PerformanceMetrics
    
    /// Safety violations that occurred
    public let violations: [ViolationRecord]
    
    /// Memory leaks detected
    public let leaks: [LeakReport]
    
    /// Errors encountered during execution
    public let errors: [Error]
    
    /// Overall execution status
    public let status: ScenarioResult.Status
    
    /// Custom metrics from the scenario
    public let customData: [String: Any]
    
    // MARK: - Computed Properties
    
    /// Whether the scenario passed
    public var passed: Bool {
        status == .passed
    }
    
    /// Whether any violations occurred
    public var hasViolations: Bool {
        !violations.isEmpty
    }
    
    /// Whether any leaks were detected
    public var hasLeaks: Bool {
        !leaks.isEmpty
    }
    
    /// Whether any errors occurred
    public var hasErrors: Bool {
        !errors.isEmpty
    }
    
    /// Total number of issues (violations + leaks + errors)
    public var issueCount: Int {
        violations.count + leaks.count + errors.count
    }
    
    /// Severity of the most critical violation
    public var maxViolationSeverity: ViolationSeverity? {
        violations.map { $0.severity }.max()
    }
    
    /// Severity of the most critical leak
    public var maxLeakSeverity: LeakSeverity? {
        leaks.map { $0.severity }.max()
    }
    
    // MARK: - Validation
    
    /// Create a validation context for this execution
    public func validate() -> ValidationContext {
        ValidationContext(execution: self)
    }
    
    /// Apply validation rules and get results
    public func validate(rules: [ScenarioTestHarness.ValidationRule]) -> [ValidationResult] {
        rules.map { rule in
            rule.validate(self)
        }
    }
    
    // MARK: - Reporting
    
    /// Generate a summary report
    public func summary() -> String {
        var report = """
        Scenario: \(scenario)
        Status: \(status)
        Duration: \(String(format: "%.2fs", duration))
        
        """
        
        if metrics.summary != "" {
            report += "Performance:\n  \(metrics.summary)\n\n"
        }
        
        if hasViolations {
            report += "Violations: \(violations.count)\n"
            for violation in violations.prefix(3) {
                report += "  - [\(violation.severity)] \(violation.type) at \(formatTime(violation.triggeredAt))\n"
            }
            if violations.count > 3 {
                report += "  ... and \(violations.count - 3) more\n"
            }
            report += "\n"
        }
        
        if hasLeaks {
            report += "Memory Leaks: \(leaks.count)\n"
            for leak in leaks.prefix(3) {
                report += "  - [\(leak.severity)] \(leak.typeName) (\(formatBytes(leak.size ?? 0)))\n"
            }
            if leaks.count > 3 {
                report += "  ... and \(leaks.count - 3) more\n"
            }
            report += "\n"
        }
        
        if hasErrors {
            report += "Errors: \(errors.count)\n"
            for error in errors.prefix(3) {
                report += "  - \(error.localizedDescription)\n"
            }
            if errors.count > 3 {
                report += "  ... and \(errors.count - 3) more\n"
            }
        }
        
        return report
    }
    
    /// Generate detailed JSON report
    public func detailedReport() -> Data? {
        let report = DetailedExecutionReport(
            scenario: scenario,
            startTime: startTime,
            endTime: endTime,
            duration: duration,
            status: status.rawValue,
            metrics: [
                "duration": duration,
                "averageCPU": metrics.averageCPU ?? 0,
                "peakMemory": metrics.peakMemory ?? 0,
                "peakTasks": metrics.peakTasks ?? 0
            ],
            violations: violations.map { violation in
                [
                    "type": violation.type.rawValue,
                    "severity": violation.severity.rawValue,
                    "time": ISO8601DateFormatter().string(from: violation.triggeredAt)
                ]
            },
            leaks: leaks.map { leak in
                [
                    "type": leak.typeName,
                    "severity": leak.severity.rawValue,
                    "size": leak.size ?? 0,
                    "age": leak.age
                ]
            },
            errors: errors.map { $0.localizedDescription }
        )
        
        return try? JSONEncoder().encode(report)
    }
    
    // MARK: - Helpers
    
    private func formatTime(_ date: Date) -> String {
        let interval = date.timeIntervalSince(startTime)
        return String(format: "%.1fs", interval)
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes)B"
        } else if bytes < 1_048_576 {
            return String(format: "%.1fKB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1fMB", Double(bytes) / 1_048_576)
        }
    }
}

// MARK: - Validation Context

/// Fluent API for validating scenario execution results
public struct ValidationContext {
    private let execution: ScenarioExecution
    
    init(execution: ScenarioExecution) {
        self.execution = execution
    }
    
    /// Validate execution time is within bounds
    public func performsWithin(seconds: TimeInterval) -> Bool {
        execution.duration <= seconds
    }
    
    /// Validate resource usage is within limits
    public func usesLessThan(memory: Int? = nil, cpu: Double? = nil, tasks: Int? = nil) -> Bool {
        if let memoryLimit = memory, let peakMemory = execution.metrics.peakMemory {
            if peakMemory > memoryLimit { return false }
        }
        
        if let cpuLimit = cpu, let avgCPU = execution.metrics.averageCPU {
            if avgCPU > cpuLimit { return false }
        }
        
        if let taskLimit = tasks, let peakTasks = execution.metrics.peakTasks {
            if peakTasks > taskLimit { return false }
        }
        
        return true
    }
    
    /// Validate no memory leaks occurred
    public func hasNoLeaks() -> Bool {
        execution.leaks.isEmpty
    }
    
    /// Validate specific number of violations
    public func triggersViolations(count: Int? = nil, severity: ViolationSeverity? = nil) -> Bool {
        var matchingViolations = execution.violations
        
        if let severityFilter = severity {
            matchingViolations = matchingViolations.filter { $0.severity >= severityFilter }
        }
        
        if let expectedCount = count {
            return matchingViolations.count == expectedCount
        }
        
        return !matchingViolations.isEmpty
    }
    
    /// Validate no errors occurred
    public func succeeds() -> Bool {
        execution.passed && execution.errors.isEmpty
    }
    
    /// Validate with custom predicate
    public func matches(_ predicate: (ScenarioExecution) -> Bool) -> Bool {
        predicate(execution)
    }
}

// MARK: - Validation Result

/// Result of applying a validation rule
public enum ValidationResult: Sendable {
    case passed
    case failed(reason: String)
    case skipped(reason: String)
    
    public var passed: Bool {
        if case .passed = self { return true }
        return false
    }
    
    public var message: String {
        switch self {
        case .passed:
            return "Passed"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .skipped(let reason):
            return "Skipped: \(reason)"
        }
    }
}

// MARK: - Detailed Report Structure

private struct DetailedExecutionReport: Codable {
    let scenario: String
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval
    let status: String
    let metrics: [String: Double]
    let violations: [[String: Any]]
    let leaks: [[String: Any]]
    let errors: [String]
    
    enum CodingKeys: String, CodingKey {
        case scenario, startTime, endTime, duration, status, metrics, violations, leaks, errors
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scenario, forKey: .scenario)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(duration, forKey: .duration)
        try container.encode(status, forKey: .status)
        try container.encode(metrics, forKey: .metrics)
        try container.encode(errors, forKey: .errors)
        
        // Encode violations and leaks as JSON-compatible dictionaries
        let jsonEncoder = JSONEncoder()
        if let violationData = try? jsonEncoder.encode(violations),
           let violationJSON = try? JSONSerialization.jsonObject(with: violationData) {
            try container.encode(violationJSON as! [[String: Any]], forKey: .violations)
        }
        
        if let leakData = try? jsonEncoder.encode(leaks),
           let leakJSON = try? JSONSerialization.jsonObject(with: leakData) {
            try container.encode(leakJSON as! [[String: Any]], forKey: .leaks)
        }
    }
}

// MARK: - XCTest Assertions

/// Assert that a scenario execution passes all validations
public func XCTAssertScenarioSucceeds(
    _ execution: ScenarioExecution,
    file: StaticString = #file,
    line: UInt = #line
) {
    XCTAssertTrue(
        execution.passed,
        "Scenario '\(execution.scenario)' failed with status: \(execution.status)",
        file: file,
        line: line
    )
    
    XCTAssertTrue(
        execution.errors.isEmpty,
        "Scenario had \(execution.errors.count) errors: \(execution.errors.map { $0.localizedDescription })",
        file: file,
        line: line
    )
}

/// Assert that a scenario has no memory leaks
public func XCTAssertNoLeaks(
    _ execution: ScenarioExecution,
    file: StaticString = #file,
    line: UInt = #line
) {
    XCTAssertTrue(
        execution.leaks.isEmpty,
        "Scenario '\(execution.scenario)' had \(execution.leaks.count) memory leaks:\n\(execution.leaks.map { "  - \($0.typeName)" }.joined(separator: "\n"))",
        file: file,
        line: line
    )
}

/// Assert that a scenario performs within time bounds
public func XCTAssertPerformance(
    _ execution: ScenarioExecution,
    within seconds: TimeInterval,
    file: StaticString = #file,
    line: UInt = #line
) {
    XCTAssertLessThanOrEqual(
        execution.duration,
        seconds,
        "Scenario '\(execution.scenario)' took \(String(format: "%.2fs", execution.duration)), expected less than \(seconds)s",
        file: file,
        line: line
    )
}