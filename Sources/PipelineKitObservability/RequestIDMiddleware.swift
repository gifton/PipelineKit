import Foundation
import PipelineKitCore

/// Middleware that ensures every command has a unique request ID for tracking
///
/// This middleware generates or propagates request IDs throughout the command
/// execution pipeline, enabling distributed tracing and correlation of logs.
///
/// ## Example Usage
/// ```swift
/// let requestID = RequestIDMiddleware(
///     headerName: "X-Request-ID",
///     generator: .uuid
/// )
/// pipeline.use(requestID)
/// ```
public struct RequestIDMiddleware: Middleware {
    public let priority: ExecutionPriority = .preProcessing
    
    // MARK: - ID Generation Strategies
    
    /// Strategy for generating request IDs
    public enum IDGenerator: Sendable {
        /// UUID v4 (default)
        case uuid
        
        /// Timestamp-based ID with optional prefix
        case timestamp(prefix: String?)
        
        /// Custom generator function
        case custom(@Sendable () -> String)
        
        /// Hierarchical ID that includes parent ID
        case hierarchical(separator: String)
        
        func generate(parentID: String? = nil) -> String {
            switch self {
            case .uuid:
                return UUID().uuidString
                
            case .timestamp(let prefix):
                let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
                let randomSuffix = String(format: "%04x", Int.random(in: 0..<65536))
                if let prefix = prefix {
                    return "\(prefix)-\(timestamp)-\(randomSuffix)"
                }
                return "\(timestamp)-\(randomSuffix)"
                
            case .custom(let generator):
                return generator()
                
            case .hierarchical(let separator):
                let newID = UUID().uuidString
                if let parentID = parentID {
                    return "\(parentID)\(separator)\(newID)"
                }
                return newID
            }
        }
    }
    
    // MARK: - Configuration
    
    public struct Configuration: Sendable {
        /// Key used to store request ID in context metadata
        public let contextKey: String
        
        /// Header name for HTTP propagation
        public let headerName: String
        
        /// ID generation strategy
        public let generator: IDGenerator
        
        /// Whether to override existing request IDs
        public let overrideExisting: Bool
        
        /// Whether to emit observability events
        public let emitEvents: Bool
        
        /// Additional metadata to include with request ID
        public let additionalMetadata: [String: String]
        
        public init(
            contextKey: String = "request_id",
            headerName: String = "X-Request-ID",
            generator: IDGenerator = .uuid,
            overrideExisting: Bool = false,
            emitEvents: Bool = true,
            additionalMetadata: [String: String] = [:]
        ) {
            self.contextKey = contextKey
            self.headerName = headerName
            self.generator = generator
            self.overrideExisting = overrideExisting
            self.emitEvents = emitEvents
            self.additionalMetadata = additionalMetadata
        }
    }
    
    private let configuration: Configuration
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public init(
        headerName: String = "X-Request-ID",
        generator: IDGenerator = .uuid
    ) {
        self.init(
            configuration: Configuration(
                headerName: headerName,
                generator: generator
            )
        )
    }
    
    // MARK: - Middleware Implementation
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let commandType = String(describing: type(of: command))
        
        // Check for existing request ID
        let existingID = extractRequestID(from: context)
        let shouldGenerateNew = existingID == nil || configuration.overrideExisting
        
        let requestID: String
        if shouldGenerateNew {
            // Generate new ID
            let parentID = existingID ?? extractParentID(from: context)
            requestID = configuration.generator.generate(parentID: parentID)
            
            // Store in context
            context.metadata[configuration.contextKey] = requestID
            
            // Add additional metadata
            for (key, value) in configuration.additionalMetadata {
                context.metadata[key] = value
            }
            
            // Emit event for new ID
            if configuration.emitEvents {
                await emitRequestIDGenerated(
                    commandType: commandType,
                    requestID: requestID,
                    parentID: parentID,
                    context: context
                )
            }
        } else {
            requestID = existingID!
            
            // Emit event for propagated ID
            if configuration.emitEvents {
                await emitRequestIDPropagated(
                    commandType: commandType,
                    requestID: requestID,
                    context: context
                )
            }
        }
        
        // Set request ID in various locations for easy access
        await propagateRequestID(requestID: requestID, context: context)
        
        // Add request ID to task-local storage if available
        return try await withRequestID(requestID) {
            try await next(command, context)
        }
    }
    
    // MARK: - Private Methods
    
    private func extractRequestID(from context: CommandContext) -> String? {
        // Check primary location
        if let id = context.metadata[configuration.contextKey] as? String {
            return id
        }
        
        // Check alternative locations
        let alternativeKeys = ["requestId", "request-id", "correlation-id", "trace-id"]
        for key in alternativeKeys {
            if let id = context.metadata[key] as? String {
                return id
            }
        }
        
        // Check HTTP headers if available
        if let headers = context.metadata["headers"] as? [String: String] {
            if let id = headers[configuration.headerName] {
                return id
            }
            // Check alternative header names
            let alternativeHeaders = ["X-Correlation-ID", "X-Trace-ID", "X-Request-Id"]
            for header in alternativeHeaders {
                if let id = headers[header] {
                    return id
                }
            }
        }
        
        return nil
    }
    
    private func extractParentID(from context: CommandContext) -> String? {
        // Check for parent ID in metadata
        let parentKeys = ["parent_request_id", "parent_id", "parent-request-id"]
        for key in parentKeys {
            if let id = context.metadata[key] as? String {
                return id
            }
        }
        return nil
    }
    
    private func propagateRequestID(requestID: String, context: CommandContext) async {
        // Ensure request ID is in standard locations
        context.metadata["correlation_id"] = requestID
        context.metadata["trace_id"] = requestID
        
        // Add to headers if present
        if var headers = context.metadata["headers"] as? [String: String] {
            headers[configuration.headerName] = requestID
            headers["X-Correlation-ID"] = requestID
            context.metadata["headers"] = headers
        }
        
        // Add timestamp if not present
        if context.metadata["request_timestamp"] == nil {
            context.metadata["request_timestamp"] = Date()
        }
    }
    
    // MARK: - Task Local Storage
    
    @TaskLocal
    private static var currentRequestID: String?
    
    private func withRequestID<T>(
        _ requestID: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await Self.$currentRequestID.withValue(requestID) {
            try await operation()
        }
    }
    
    /// Gets the current request ID from task-local storage
    public static var current: String? {
        currentRequestID
    }
    
    // MARK: - Observability Events
    
    private func emitRequestIDGenerated(
        commandType: String,
        requestID: String,
        parentID: String?,
        context: CommandContext
    ) async {
        var properties: [String: Sendable] = [
            "command_type": commandType,
            "request_id": requestID,
            "generator_type": String(describing: configuration.generator)
        ]
        
        if let parentID = parentID {
            properties["parent_id"] = parentID
        }
        
        context.emitCustomEvent("request_id_generated", properties: properties)
    }
    
    private func emitRequestIDPropagated(
        commandType: String,
        requestID: String,
        context: CommandContext
    ) async {
        context.emitCustomEvent(
            "request_id_propagated",
            properties: [
                "command_type": commandType,
                "request_id": requestID
            ]
        )
    }
}

// MARK: - Public API Extensions

public extension RequestIDMiddleware {
    /// Creates middleware for HTTP services
    static func forHTTP(headerName: String = "X-Request-ID") -> RequestIDMiddleware {
        RequestIDMiddleware(
            configuration: Configuration(
                headerName: headerName,
                generator: .uuid,
                additionalMetadata: [
                    "service_name": ProcessInfo.processInfo.processName,
                    "service_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                ]
            )
        )
    }
    
    /// Creates middleware for microservices with hierarchical IDs
    static func forMicroservices(serviceName: String) -> RequestIDMiddleware {
        RequestIDMiddleware(
            configuration: Configuration(
                generator: .hierarchical(separator: "::"),
                additionalMetadata: [
                    "service": serviceName,
                    "instance_id": UUID().uuidString
                ]
            )
        )
    }
    
    /// Creates middleware with timestamp-based IDs
    static func withTimestamp(prefix: String? = nil) -> RequestIDMiddleware {
        RequestIDMiddleware(
            configuration: Configuration(
                generator: .timestamp(prefix: prefix)
            )
        )
    }
    
    /// Creates middleware that generates short IDs for logging
    static func shortIDs() -> RequestIDMiddleware {
        RequestIDMiddleware(
            configuration: Configuration(
                generator: .custom {
                    // Generate 8-character alphanumeric ID
                    let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                    return String((0..<8).map { _ in characters.randomElement()! })
                }
            )
        )
    }
}

// MARK: - Command Context Extensions

public extension CommandContext {
    /// Gets the request ID from the context
    var requestID: String? {
        metadata["request_id"] as? String
    }
    
    /// Gets the correlation ID from the context (alias for request ID)
    var correlationID: String? {
        metadata["correlation_id"] as? String ?? requestID
    }
    
    /// Gets the trace ID from the context (alias for request ID)
    var traceID: String? {
        metadata["trace_id"] as? String ?? requestID
    }
}

// MARK: - Integration Support

/// Protocol for commands that need access to request ID
public protocol RequestIDAccessible {
    var requestID: String? { get }
}

/// Extension to make request ID easily accessible in logs
public extension LogFormatter {
    /// Creates a log formatter that includes request ID
    static func withRequestID() -> RequestIDLogFormatter {
        RequestIDLogFormatter()
    }
}

/// Log formatter that automatically includes request ID
public struct RequestIDLogFormatter: LogFormatter {
    public init() {}
    
    public func formatCommandStart<T: Command>(
        commandType: String,
        requestId: String,
        command: T,
        context: CommandContext
    ) -> String {
        "[\(requestId)] Command started: \(commandType)"
    }
    
    public func formatCommandSuccess<R>(
        commandType: String,
        requestId: String,
        result: R,
        duration: TimeInterval,
        context: CommandContext
    ) -> String {
        "[\(requestId)] Command completed: \(commandType) (duration: \(String(format: "%.3f", duration))s)"
    }
    
    public func formatCommandFailure(
        commandType: String,
        requestId: String,
        error: Error,
        duration: TimeInterval,
        context: CommandContext
    ) -> String {
        "[\(requestId)] Command failed: \(commandType) - \(error) (duration: \(String(format: "%.3f", duration))s)"
    }
}