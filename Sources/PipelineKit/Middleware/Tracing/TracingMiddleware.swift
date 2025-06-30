import Foundation

/// Middleware that provides distributed tracing capabilities for commands.
///
/// This middleware integrates with distributed tracing systems to track command
/// execution across services. It creates spans, propagates trace context, and
/// records timing and metadata.
///
/// ## Example Usage
/// ```swift
/// let tracer = StandardTracer(serviceName: "api-service")
/// let middleware = TracingMiddleware(
///     tracer: tracer,
///     spanNamer: { command in
///         "\(type(of: command)).execute"
///     }
/// )
/// ```
public final class TracingMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .tracing
    
    private let tracer: any Tracer
    private let spanNamer: @Sendable (any Command) -> String
    private let includeCommandData: Bool
    
    /// Creates a tracing middleware with the specified configuration.
    ///
    /// - Parameters:
    ///   - tracer: The tracer implementation to use
    ///   - spanNamer: Function to generate span names from commands
    ///   - includeCommandData: Whether to include command data in span attributes
    public init(
        tracer: any Tracer,
        spanNamer: @escaping @Sendable (any Command) -> String = TracingMiddleware.defaultSpanNamer,
        includeCommandData: Bool = false
    ) {
        self.tracer = tracer
        self.spanNamer = spanNamer
        self.includeCommandData = includeCommandData
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Extract parent trace context if available
        let parentContext = await context.get(TraceContextKey.self)
        
        // Start a new span
        let spanName = spanNamer(command)
        let span = await tracer.startSpan(
            name: spanName,
            parent: parentContext,
            attributes: [
                "command.type": String(describing: type(of: command)),
                "command.id": await context.commandMetadata.correlationId ?? "unknown"
            ]
        )
        
        // Add command data if requested
        if includeCommandData, let describable = command as? CustomStringConvertible {
            await span.setAttribute("command.data", value: describable.description)
        }
        
        // Store trace context for downstream middleware/handlers
        await context.set(span.context, for: TraceContextKey.self)
        
        // Emit tracing started event
        await context.emitCustomEvent(
            "tracing.span.started",
            properties: [
                "span.id": span.context.spanId,
                "trace.id": span.context.traceId,
                "span.name": spanName
            ]
        )
        
        do {
            // Execute the command
            let result = try await next(command, context)
            
            // Mark span as successful
            await span.setStatus(.ok)
            
            // Add result info if it's describable
            if includeCommandData, let describable = result as? CustomStringConvertible {
                await span.setAttribute("command.result", value: describable.description)
            }
            
            // End the span
            await span.end()
            
            // Emit tracing completed event
            await context.emitCustomEvent(
                "tracing.span.completed",
                properties: [
                    "span.id": span.context.spanId,
                    "trace.id": span.context.traceId,
                    "span.name": spanName,
                    "duration": span.duration ?? 0
                ]
            )
            
            return result
            
        } catch {
            // Mark span as failed
            await span.setStatus(.error(message: error.localizedDescription))
            await span.setAttribute("error.type", value: String(describing: type(of: error)))
            await span.setAttribute("error.message", value: error.localizedDescription)
            
            // End the span
            await span.end()
            
            // Emit tracing failed event
            await context.emitCustomEvent(
                "tracing.span.failed",
                properties: [
                    "span.id": span.context.spanId,
                    "trace.id": span.context.traceId,
                    "span.name": spanName,
                    "error": String(describing: error),
                    "duration": span.duration ?? 0
                ]
            )
            
            throw error
        }
    }
    
    /// Default span namer using command type
    @Sendable
    public static func defaultSpanNamer(_ command: any Command) -> String {
        "\(type(of: command))"
    }
}

// MARK: - Tracer Protocol

/// Protocol for distributed tracing implementations.
public protocol Tracer: Sendable {
    /// Starts a new span.
    func startSpan(
        name: String,
        parent: TraceContext?,
        attributes: [String: String]
    ) async -> any Span
    
    /// Extracts trace context from carrier (e.g., HTTP headers).
    func extract(from carrier: [String: String]) async -> TraceContext?
    
    /// Injects trace context into carrier (e.g., HTTP headers).
    func inject(context: TraceContext, into carrier: inout [String: String]) async
}

// MARK: - Span Protocol

/// Protocol representing a trace span.
public protocol Span: Sendable {
    /// The span's trace context.
    var context: TraceContext { get }
    
    /// The span's duration in seconds (nil if not ended).
    var duration: TimeInterval? { get }
    
    /// Sets an attribute on the span.
    func setAttribute(_ key: String, value: String) async
    
    /// Sets the span status.
    func setStatus(_ status: SpanStatus) async
    
    /// Ends the span.
    func end() async
}

// MARK: - Trace Context

/// Context for distributed tracing.
public struct TraceContext: Sendable {
    public let traceId: String
    public let spanId: String
    public let traceFlags: UInt8
    public let traceState: String?
    
    public init(
        traceId: String,
        spanId: String,
        traceFlags: UInt8 = 0,
        traceState: String? = nil
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.traceFlags = traceFlags
        self.traceState = traceState
    }
}

// MARK: - Span Status

/// Status of a span.
public enum SpanStatus: Sendable {
    case unset
    case ok
    case error(message: String)
}

// MARK: - Standard Tracer Implementation

/// Standard in-memory tracer for development and testing.
public actor StandardTracer: Tracer {
    public struct RecordedSpan: Sendable {
        public let name: String
        public let context: TraceContext
        public let parent: TraceContext?
        public let startTime: Date
        public let endTime: Date?
        public let attributes: [String: String]
        public let status: SpanStatus
        
        public var duration: TimeInterval? {
            guard let endTime = endTime else { return nil }
            return endTime.timeIntervalSince(startTime)
        }
    }
    
    private let serviceName: String
    private var spans: [String: StandardSpan] = [:]
    private var completedSpans: [RecordedSpan] = []
    
    public init(serviceName: String) {
        self.serviceName = serviceName
    }
    
    public func startSpan(
        name: String,
        parent: TraceContext?,
        attributes: [String: String]
    ) async -> any Span {
        let context = TraceContext(
            traceId: parent?.traceId ?? UUID().uuidString,
            spanId: UUID().uuidString
        )
        
        var allAttributes = attributes
        allAttributes["service.name"] = serviceName
        
        let span = StandardSpan(
            name: name,
            context: context,
            parent: parent,
            tracer: self,
            attributes: allAttributes
        )
        
        spans[context.spanId] = span
        return span
    }
    
    public func extract(from carrier: [String: String]) async -> TraceContext? {
        guard let traceId = carrier["trace-id"],
              let spanId = carrier["span-id"] else {
            return nil
        }
        
        let traceFlags = UInt8(carrier["trace-flags"] ?? "0") ?? 0
        let traceState = carrier["trace-state"]
        
        return TraceContext(
            traceId: traceId,
            spanId: spanId,
            traceFlags: traceFlags,
            traceState: traceState
        )
    }
    
    public func inject(context: TraceContext, into carrier: inout [String: String]) async {
        carrier["trace-id"] = context.traceId
        carrier["span-id"] = context.spanId
        carrier["trace-flags"] = String(context.traceFlags)
        if let traceState = context.traceState {
            carrier["trace-state"] = traceState
        }
    }
    
    /// Records a completed span.
    func recordSpan(_ span: StandardSpan, endTime: Date) {
        let recorded = RecordedSpan(
            name: span.name,
            context: span.context,
            parent: span.parent,
            startTime: span.startTime,
            endTime: endTime,
            attributes: span.attributes,
            status: span.status
        )
        
        completedSpans.append(recorded)
        spans.removeValue(forKey: span.context.spanId)
    }
    
    /// Gets all completed spans.
    public func getCompletedSpans() -> [RecordedSpan] {
        completedSpans
    }
    
    /// Clears all recorded spans.
    public func clear() {
        spans.removeAll()
        completedSpans.removeAll()
    }
}

// MARK: - Standard Span Implementation

final class StandardSpan: Span, @unchecked Sendable {
    let name: String
    let context: TraceContext
    let parent: TraceContext?
    let startTime: Date
    private let tracer: StandardTracer
    
    private(set) var attributes: [String: String]
    private(set) var status: SpanStatus = .unset
    private var ended = false
    private var endTime: Date?
    
    var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }
    
    init(
        name: String,
        context: TraceContext,
        parent: TraceContext?,
        tracer: StandardTracer,
        attributes: [String: String] = [:]
    ) {
        self.name = name
        self.context = context
        self.parent = parent
        self.tracer = tracer
        self.startTime = Date()
        self.attributes = attributes
    }
    
    func setAttribute(_ key: String, value: String) async {
        guard !ended else { return }
        attributes[key] = value
    }
    
    func setStatus(_ status: SpanStatus) async {
        guard !ended else { return }
        self.status = status
    }
    
    func end() async {
        guard !ended else { return }
        ended = true
        endTime = Date()
        await tracer.recordSpan(self, endTime: endTime!)
    }
}

// MARK: - Context Key

private struct TraceContextKey: ContextKey {
    typealias Value = TraceContext
}

// MARK: - Convenience Extensions

public extension TracingMiddleware {
    /// Creates a tracing middleware with service name.
    convenience init(serviceName: String, includeCommandData: Bool = false) {
        let tracer = StandardTracer(serviceName: serviceName)
        self.init(tracer: tracer, includeCommandData: includeCommandData)
    }
    
    /// Creates a tracing middleware for HTTP services.
    static func http(
        serviceName: String,
        tracer: any Tracer,
        headerPrefix: String = "X-Trace-"
    ) -> TracingMiddleware {
        TracingMiddleware(
            tracer: tracer,
            spanNamer: { command in
                if let httpCommand = command as? any HTTPCommand {
                    return "\(httpCommand.method) \(httpCommand.path)"
                }
                return defaultSpanNamer(command)
            }
        )
    }
}

// MARK: - HTTP Command Protocol

/// Protocol for HTTP-based commands.
public protocol HTTPCommand: Command {
    var method: String { get }
    var path: String { get }
}