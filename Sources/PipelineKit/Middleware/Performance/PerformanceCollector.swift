import Foundation

/// Protocol for collecting performance measurements
public protocol PerformanceCollector: Sendable {
    /// Records a performance measurement
    func record(_ measurement: PerformanceMeasurement) async
}

/// Sendable type for performance metric values
public enum PerformanceMetricValue: Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case data(Data)
    
    /// Convenience accessors
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
    
    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }
    
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    
    public var dataValue: Data? {
        if case .data(let value) = self { return value }
        return nil
    }
}

/// A performance measurement for a command execution
public struct PerformanceMeasurement: Sendable {
    public let commandName: String
    public let executionTime: TimeInterval
    public let isSuccess: Bool
    public let errorMessage: String?
    public let metrics: [String: PerformanceMetricValue]
    
    public init(
        commandName: String,
        executionTime: TimeInterval,
        isSuccess: Bool,
        errorMessage: String? = nil,
        metrics: [String: PerformanceMetricValue] = [:]
    ) {
        self.commandName = commandName
        self.executionTime = executionTime
        self.isSuccess = isSuccess
        self.errorMessage = errorMessage
        self.metrics = metrics
    }
}

/// Context key for storing performance measurements
public struct PerformanceMeasurementKey: ContextKey {
    public typealias Value = PerformanceMeasurement
}
