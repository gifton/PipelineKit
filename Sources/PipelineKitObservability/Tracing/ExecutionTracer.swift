//
//  ExecutionTracer.swift
//  PipelineKitObservability
//
//  Distributed tracing for command execution flows
//

import Foundation
import PipelineKitCore

// MARK: - Span Types

/// Unique identifier for a span
public struct SpanID: Hashable, Sendable {
    let value: UUID

    init() {
        self.value = UUID()
    }
}

/// Result of a span execution
public enum SpanResult: Sendable {
    case success
    case failure(String) // Use String instead of Error for Sendable

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// A single unit of work in a trace
public struct Span: Sendable {
    /// Unique identifier
    public let id: SpanID

    /// Span name (e.g., "middleware.Validation", "handler.CreateUser")
    public let name: String

    /// When the span started
    public let startTime: Date

    /// When the span ended (nil if still running)
    public var endTime: Date?

    /// Duration in milliseconds
    public var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime) * 1000
    }

    /// Result of the span
    public var result: SpanResult?

    /// Parent span ID (for nested spans)
    public let parentID: SpanID?

    internal init(
        id: SpanID,
        name: String,
        startTime: Date,
        endTime: Date? = nil,
        result: SpanResult? = nil,
        parentID: SpanID? = nil
    ) {
        self.id = id
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.result = result
        self.parentID = parentID
    }
}

/// A complete trace of a request's execution
public struct Trace: Sendable {
    /// Correlation ID linking related events
    public let correlationID: String

    /// All spans in execution order
    public var spans: [Span]

    /// When the trace started
    public let startTime: Date

    /// When the trace ended
    public var endTime: Date?

    /// Total duration in milliseconds
    public var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime) * 1000
    }

    internal init(
        correlationID: String,
        spans: [Span],
        startTime: Date,
        endTime: Date? = nil
    ) {
        self.correlationID = correlationID
        self.spans = spans
        self.startTime = startTime
        self.endTime = endTime
    }
}

// MARK: - ExecutionTracer

/// Actor that manages execution traces for requests
///
/// The ExecutionTracer collects timing and result information for each step
/// of command execution, providing detailed insights into performance and errors.
///
/// ## Usage
/// ```swift
/// let tracer = ExecutionTracer()
///
/// // Attach to pipeline via middleware
/// await pipeline.addMiddleware(TracingMiddleware(tracer: tracer))
///
/// // Execute commands (traces are collected automatically)
/// try await pipeline.execute(command, context: context)
///
/// // Retrieve trace
/// if let trace = await tracer.getTrace(correlationID: context.correlationID) {
///     await tracer.printTrace(trace)
/// }
/// ```
public actor ExecutionTracer {
    /// Active traces by correlation ID
    private var traces: [String: Trace] = [:]

    /// Maximum traces to keep in memory
    private let maxTraces: Int

    /// Trace retention time (old traces are purged)
    private let retentionTime: TimeInterval

    /// Configuration for ExecutionTracer
    public struct Configuration: Sendable {
        public let maxTraces: Int
        public let retentionTime: TimeInterval

        public init(maxTraces: Int = 1000, retentionTime: TimeInterval = 300) {
            self.maxTraces = maxTraces
            self.retentionTime = retentionTime
        }

        public static let `default` = Configuration()
    }

    public init(configuration: Configuration = .default) {
        self.maxTraces = configuration.maxTraces
        self.retentionTime = configuration.retentionTime
    }

    // MARK: - Span Management

    /// Start a new span in a trace
    ///
    /// - Parameters:
    ///   - name: Name of the span (e.g., "middleware.Validation")
    ///   - correlationID: Correlation ID for the trace
    ///   - parentID: Optional parent span ID for nesting
    /// - Returns: Span ID for ending the span later
    public func startSpan(
        name: String,
        correlationID: String,
        parentID: SpanID? = nil
    ) -> SpanID {
        let spanID = SpanID()
        let span = Span(
            id: spanID,
            name: name,
            startTime: Date(),
            endTime: nil,
            result: nil,
            parentID: parentID
        )

        // Get or create trace
        if traces[correlationID] == nil {
            traces[correlationID] = Trace(
                correlationID: correlationID,
                spans: [],
                startTime: Date(),
                endTime: nil
            )
        }

        traces[correlationID]?.spans.append(span)

        // Purge old traces if needed
        purgeOldTracesIfNeeded()

        return spanID
    }

    /// End a span with a result
    ///
    /// - Parameters:
    ///   - spanID: The span ID returned from startSpan()
    ///   - correlationID: Correlation ID for the trace
    ///   - result: Success or failure
    public func endSpan(
        _ spanID: SpanID,
        correlationID: String,
        result: SpanResult
    ) {
        guard var trace = traces[correlationID] else { return }

        // Find and update the span
        if let index = trace.spans.firstIndex(where: { $0.id == spanID }) {
            trace.spans[index].endTime = Date()
            trace.spans[index].result = result
        }

        // Check if all spans are complete
        let allComplete = trace.spans.allSatisfy { $0.endTime != nil }
        if allComplete {
            trace.endTime = Date()
        }

        traces[correlationID] = trace
    }

    // MARK: - Trace Retrieval

    /// Get a trace by correlation ID
    public func getTrace(correlationID: String) -> Trace? {
        traces[correlationID]
    }

    /// Get all active traces
    public func getAllTraces() -> [Trace] {
        Array(traces.values)
    }

    /// Clear a specific trace
    public func clearTrace(correlationID: String) {
        traces.removeValue(forKey: correlationID)
    }

    /// Clear all traces
    public func clearAllTraces() {
        traces.removeAll()
    }

    // MARK: - Formatting

    /// Print a formatted trace to the console
    ///
    /// Outputs a human-readable trace showing execution flow, timing, and results.
    ///
    /// ## Example Output
    /// ```
    /// ============================================================
    /// Execution Trace: req-abc-123
    /// ============================================================
    /// Total Duration: 125.34ms
    ///
    /// Execution Flow:
    ///   ✅ middleware.Validation                          2.14ms
    ///   ✅ middleware.Authentication                      8.52ms
    ///   ✅ handler.CreateUser                            28.15ms
    /// ============================================================
    /// ```
    public func printTrace(_ trace: Trace) {
        print("\n" + String(repeating: "=", count: 60))
        print("Execution Trace: \(trace.correlationID)")
        print(String(repeating: "=", count: 60))

        if let duration = trace.duration {
            print("Total Duration: \(String(format: "%.2f", duration))ms")
        } else {
            print("Status: IN PROGRESS")
        }

        print("\nExecution Flow:")

        for span in trace.spans {
            let status: String
            if let result = span.result {
                status = result.isSuccess ? "✅" : "❌"
            } else {
                status = "⏳"
            }

            let durationStr: String
            if let duration = span.duration {
                durationStr = String(format: "%.2f", duration) + "ms"
            } else {
                durationStr = "running..."
            }

            print("  \(status) \(span.name.padding(toLength: 40, withPad: " ", startingAt: 0)) \(durationStr)")

            // Show error if failed
            if case .failure(let errorMsg) = span.result {
                print("     ↳ Error: \(errorMsg)")
            }
        }

        print(String(repeating: "=", count: 60) + "\n")
    }

    /// Get trace as JSON string
    ///
    /// - Parameter trace: The trace to export
    /// - Returns: JSON representation of the trace
    /// - Throws: EncodingError if serialization fails
    public func traceAsJSON(_ trace: Trace) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(TraceDTO.from(trace))
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Maintenance

    private func purgeOldTracesIfNeeded() {
        // Remove old traces if we exceed max
        if traces.count > maxTraces {
            let cutoff = Date().addingTimeInterval(-retentionTime)
            traces = traces.filter { _, trace in
                trace.startTime > cutoff
            }
        }
    }
}

// MARK: - JSON DTO

private struct TraceDTO: Codable {
    let correlationID: String
    let spans: [SpanDTO]
    let startTime: Date
    let endTime: Date?
    let durationMs: Double?

    static func from(_ trace: Trace) -> TraceDTO {
        TraceDTO(
            correlationID: trace.correlationID,
            spans: trace.spans.map { SpanDTO.from($0) },
            startTime: trace.startTime,
            endTime: trace.endTime,
            durationMs: trace.duration
        )
    }
}

private struct SpanDTO: Codable {
    let name: String
    let startTime: Date
    let endTime: Date?
    let durationMs: Double?
    let success: Bool?

    static func from(_ span: Span) -> SpanDTO {
        SpanDTO(
            name: span.name,
            startTime: span.startTime,
            endTime: span.endTime,
            durationMs: span.duration,
            success: span.result?.isSuccess
        )
    }
}
