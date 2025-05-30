import Foundation

/// Performance measurement data captured during command execution.
public struct PerformanceMeasurement: Sendable {
    /// Name of the command that was executed
    public let commandName: String
    
    /// Total execution time in seconds
    public let executionTime: TimeInterval
    
    /// Start time of the command execution
    public let startTime: Date
    
    /// End time of the command execution
    public let endTime: Date
    
    /// Whether the command execution was successful
    public let isSuccess: Bool
    
    /// Error message if execution failed
    public let errorMessage: String?
    
    /// Additional performance metrics
    public let metrics: [String: Any]
    
    public init(
        commandName: String,
        executionTime: TimeInterval,
        startTime: Date,
        endTime: Date,
        isSuccess: Bool,
        errorMessage: String? = nil,
        metrics: [String: Any] = [:]
    ) {
        self.commandName = commandName
        self.executionTime = executionTime
        self.startTime = startTime
        self.endTime = endTime
        self.isSuccess = isSuccess
        self.errorMessage = errorMessage
        self.metrics = metrics
    }
}

/// Protocol for performance measurement collectors.
public protocol PerformanceCollector: Sendable {
    /// Records a performance measurement.
    func record(_ measurement: PerformanceMeasurement) async
}

/// Context key for storing performance measurements.
public struct PerformanceMeasurementKey: ContextKey {
    public typealias Value = PerformanceMeasurement
    public static let defaultValue: PerformanceMeasurement? = nil
}

/// Middleware that measures command execution performance.
/// 
/// This middleware captures detailed timing information about command execution,
/// including start time, end time, duration, and success/failure status.
/// Performance data can be collected and reported through custom collectors.
/// 
/// Example usage:
/// ```swift
/// let performanceMiddleware = PerformanceMiddleware { measurement in
///     print("Command \(measurement.commandName) took \(measurement.executionTime)s")
/// }
/// ```
public struct PerformanceMiddleware: ContextAwareMiddleware {
    private let collector: PerformanceCollector?
    private let includeDetailedMetrics: Bool
    
    public init(
        collector: PerformanceCollector? = nil,
        includeDetailedMetrics: Bool = false
    ) {
        self.collector = collector
        self.includeDetailedMetrics = includeDetailedMetrics
    }
    
    /// Convenience initializer with closure-based collector.
    public init(
        includeDetailedMetrics: Bool = false,
        recordMeasurement: @escaping @Sendable (PerformanceMeasurement) async -> Void
    ) {
        self.collector = ClosurePerformanceCollector(recordMeasurement: recordMeasurement)
        self.includeDetailedMetrics = includeDetailedMetrics
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        let commandName = String(describing: T.self)
        
        var additionalMetrics: [String: Any] = [:]
        
        if includeDetailedMetrics {
            additionalMetrics["memoryUsage"] = getMemoryUsage()
            additionalMetrics["threadId"] = Thread.current.name ?? "unknown"
        }
        
        do {
            let result = try await next(command, context)
            let endTime = Date()
            let executionTime = endTime.timeIntervalSince(startTime)
            
            let measurement = PerformanceMeasurement(
                commandName: commandName,
                executionTime: executionTime,
                startTime: startTime,
                endTime: endTime,
                isSuccess: true,
                errorMessage: nil,
                metrics: additionalMetrics
            )
            
            // Store measurement in context for other middleware to access
            await context.set(measurement, for: PerformanceMeasurementKey.self)
            
            // Report to collector if available
            await collector?.record(measurement)
            
            return result
        } catch {
            let endTime = Date()
            let executionTime = endTime.timeIntervalSince(startTime)
            
            let measurement = PerformanceMeasurement(
                commandName: commandName,
                executionTime: executionTime,
                startTime: startTime,
                endTime: endTime,
                isSuccess: false,
                errorMessage: error.localizedDescription,
                metrics: additionalMetrics
            )
            
            // Store measurement in context for other middleware to access
            await context.set(measurement, for: PerformanceMeasurementKey.self)
            
            // Report to collector if available
            await collector?.record(measurement)
            
            throw error
        }
    }
    
    private func getMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
}

/// Internal closure-based performance collector implementation.
private struct ClosurePerformanceCollector: PerformanceCollector {
    let recordMeasurement: @Sendable (PerformanceMeasurement) async -> Void
    
    func record(_ measurement: PerformanceMeasurement) async {
        await recordMeasurement(measurement)
    }
}