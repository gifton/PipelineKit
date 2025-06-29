import Foundation

/// Performance measurement data captured during command execution.
public struct PerformanceMeasurement: Sendable {
    public let commandName: String
    public let executionTime: TimeInterval
    public let startTime: Date
    public let endTime: Date
    public let isSuccess: Bool
    public let errorMessage: String?
    public let metrics: [String: String]

    public init(
        commandName: String,
        executionTime: TimeInterval,
        startTime: Date,
        endTime: Date,
        isSuccess: Bool,
        errorMessage: String? = nil,
        metrics: [String: String] = [:]
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
    func record(_ measurement: PerformanceMeasurement) async
}

/// Context key for storing performance measurements.
public struct PerformanceMeasurementKey: ContextKey {
    public typealias Value = PerformanceMeasurement
    public static let defaultValue: PerformanceMeasurement? = nil
}

/// Middleware that measures command execution performance.
public struct PerformanceMiddleware: Middleware {
    public let priority: ExecutionPriority = .monitoring
    private let collector: PerformanceCollector?
    private let includeDetailedMetrics: Bool

    public init(
        collector: PerformanceCollector? = nil,
        includeDetailedMetrics: Bool = false
    ) {
        self.collector = collector
        self.includeDetailedMetrics = includeDetailedMetrics
    }

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

        var additionalMetrics: [String: String] = [:]

        if includeDetailedMetrics {
            additionalMetrics["memoryUsage"] = String(getMemoryUsage())
            additionalMetrics["processId"] = String(ProcessInfo.processInfo.processIdentifier)
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

            await context.set(measurement, for: PerformanceMeasurementKey.self)
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

            await context.set(measurement, for: PerformanceMeasurementKey.self)
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

private struct ClosurePerformanceCollector: PerformanceCollector {
    let recordMeasurement: @Sendable (PerformanceMeasurement) async -> Void

    func record(_ measurement: PerformanceMeasurement) async {
        await recordMeasurement(measurement)
    }
}
