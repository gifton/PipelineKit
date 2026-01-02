//
//  TracingMiddleware.swift
//  PipelineKitObservability
//
//  Automatic tracing middleware for command execution
//

import Foundation
import PipelineKitCore

/// Middleware that automatically traces command execution
///
/// This middleware works with ExecutionTracer to record detailed timing
/// and result information for each middleware in the pipeline.
///
/// ## Usage
/// ```swift
/// let tracer = ExecutionTracer()
///
/// await pipeline.addMiddleware(TracingMiddleware(tracer: tracer))
/// await pipeline.addMiddleware(ValidationMiddleware())
/// await pipeline.addMiddleware(AuthenticationMiddleware())
///
/// // Execute command
/// let context = CommandContext()
/// try await pipeline.execute(command, context: context)
///
/// // View trace
/// if let trace = await tracer.getTrace(correlationID: context.correlationID!) {
///     await tracer.printTrace(trace)
/// }
/// ```
public struct TracingMiddleware: Middleware {
    public let priority: ExecutionPriority

    private let tracer: ExecutionTracer
    private let includeHandlerSpan: Bool

    /// Creates a tracing middleware
    ///
    /// - Parameters:
    ///   - tracer: The execution tracer to record spans in
    ///   - priority: Execution priority (default: .observability to wrap other middleware)
    ///   - includeHandlerSpan: Whether to create a span for the handler (default: true)
    public init(
        tracer: ExecutionTracer,
        priority: ExecutionPriority = .observability,
        includeHandlerSpan: Bool = true
    ) {
        self.tracer = tracer
        self.priority = priority
        self.includeHandlerSpan = includeHandlerSpan
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        // Get or create correlation ID
        let correlationID = context.correlationID ?? {
            let id = UUID().uuidString
            context.correlationID = id
            return id
        }()

        // Determine span name
        let spanName: String
        if includeHandlerSpan {
            spanName = "pipeline.\(String(describing: T.self))"
        } else {
            spanName = "middleware.\(String(describing: type(of: self)))"
        }

        // Start span
        let spanID = await tracer.startSpan(
            name: spanName,
            correlationID: correlationID
        )

        do {
            let result = try await next(command, context)

            // End span with success
            await tracer.endSpan(spanID, correlationID: correlationID, result: .success)

            return result
        } catch {
            // End span with failure
            let errorMessage = String(describing: error)
            await tracer.endSpan(spanID, correlationID: correlationID, result: .failure(errorMessage))

            throw error
        }
    }
}

// MARK: - Convenience Extensions

public extension ExecutionTracer {
    /// Create a tracing middleware that uses this tracer
    ///
    /// - Parameters:
    ///   - priority: Execution priority (default: .observability)
    ///   - includeHandlerSpan: Whether to trace the handler (default: true)
    /// - Returns: Configured TracingMiddleware
    func middleware(
        priority: ExecutionPriority = .observability,
        includeHandlerSpan: Bool = true
    ) -> TracingMiddleware {
        TracingMiddleware(
            tracer: self,
            priority: priority,
            includeHandlerSpan: includeHandlerSpan
        )
    }
}
