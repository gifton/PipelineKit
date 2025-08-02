import Foundation
import PipelineKitCore

/// Middleware that tracks command execution performance
public struct PerformanceMiddleware: Middleware {
    public let priority: ExecutionPriority = .postProcessing
    
    private let collector: (any PerformanceCollector)?
    private let includeDetailedMetrics: Bool
    
    public init(
        collector: (any PerformanceCollector)? = nil,
        includeDetailedMetrics: Bool = false
    ) {
        self.collector = collector
        self.includeDetailedMetrics = includeDetailedMetrics
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = CFAbsoluteTimeGetCurrent()
        let commandName = String(describing: type(of: command))
        
        do {
            let result = try await next(command, context)
            
            // Record success
            let executionTime = CFAbsoluteTimeGetCurrent() - startTime
            await recordMeasurement(
                commandName: commandName,
                executionTime: executionTime,
                isSuccess: true,
                errorMessage: nil,
                context: context
            )
            
            return result
        } catch {
            // Record failure
            let executionTime = CFAbsoluteTimeGetCurrent() - startTime
            await recordMeasurement(
                commandName: commandName,
                executionTime: executionTime,
                isSuccess: false,
                errorMessage: error.localizedDescription,
                context: context
            )
            
            throw error
        }
    }
    
    private func recordMeasurement(
        commandName: String,
        executionTime: TimeInterval,
        isSuccess: Bool,
        errorMessage: String?,
        context: CommandContext
    ) async {
        var metrics: [String: PerformanceMetricValue] = [:]
        
        if includeDetailedMetrics {
            metrics["memoryUsage"] = .int(Int(ProcessInfo.processInfo.physicalMemory))
            metrics["processId"] = .int(Int(ProcessInfo.processInfo.processIdentifier))
        }
        
        let measurement = PerformanceMeasurement(
            commandName: commandName,
            executionTime: executionTime,
            isSuccess: isSuccess,
            errorMessage: errorMessage,
            metrics: metrics
        )
        
        // Store in context
        context.set(PerformanceData(measurement), for: PerformanceMeasurementKey.self)
        
        // Send to collector if available
        if let collector = collector {
            await collector.record(measurement)
        }
    }
}