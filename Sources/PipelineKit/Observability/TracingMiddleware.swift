import Foundation

/// Middleware that provides distributed tracing capabilities
public final class TracingMiddleware: Middleware {
    public let priority: ExecutionPriority = .tracing
    private let serviceName: String
    private let tracer: any Tracer
    
    public init(serviceName: String, tracer: any Tracer = DefaultTracer()) {
        self.serviceName = serviceName
        self.tracer = tracer
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Get or create trace ID
        let traceId = await context[TraceIdKey.self] ?? UUID().uuidString
        await context.set(traceId, for: TraceIdKey.self)
        await context.set(serviceName, for: ServiceNameKey.self)
        
        // Create span
        let span = tracer.startSpan(
            name: String(describing: T.self),
            traceId: traceId,
            attributes: [
                "service.name": serviceName,
                "command.type": String(describing: T.self)
            ]
        )
        
        do {
            let result = try await next(command, context)
            span.setStatus(.ok)
            span.end()
            return result
        } catch {
            span.setStatus(.error(error))
            span.end()
            throw error
        }
    }
}

// MARK: - Context Keys
public struct TraceIdKey: ContextKey {
    public typealias Value = String
}

public struct ServiceNameKey: ContextKey {
    public typealias Value = String
}

// MARK: - Tracer Protocol
/// Basic tracer protocol
public protocol Tracer: Sendable {
    func startSpan(name: String, traceId: String, attributes: [String: Any]) -> any Span
}

public protocol Span: Sendable {
    func setStatus(_ status: SpanStatus)
    func end()
}

public enum SpanStatus {
    case ok
    case error(Error)
}

// MARK: - Default Implementation
/// Default no-op implementation
struct DefaultTracer: Tracer {
    func startSpan(name: String, traceId: String, attributes: [String: Any]) -> any Span {
        NoOpSpan()
    }
}

struct NoOpSpan: Span {
    func setStatus(_ status: SpanStatus) {}
    func end() {}
}