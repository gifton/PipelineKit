import Foundation

/// Middleware provides cross-cutting functionality in the command pipeline.
/// 
/// Middleware components can intercept command execution to provide features like:
/// - Authentication and authorization
/// - Logging and monitoring
/// - Validation and sanitization
/// - Rate limiting and throttling
/// - Error handling and retry logic
/// 
/// Middleware follows the chain of responsibility pattern, where each middleware
/// can choose to pass execution to the next middleware or short-circuit the chain.
/// 
/// Example:
/// ```swift
/// struct LoggingMiddleware: Middleware {
///     let logger: Logger
///     
///     func execute<T: Command>(
///         _ command: T,
///         metadata: CommandMetadata,
///         next: @Sendable (T, CommandMetadata) async throws -> T.Result
///     ) async throws -> T.Result {
///         logger.info("Executing command: \(T.self)")
///         
///         do {
///             let result = try await next(command, metadata)
///             logger.info("Command succeeded: \(T.self)")
///             return result
///         } catch {
///             logger.error("Command failed: \(T.self), error: \(error)")
///             throw error
///         }
///     }
/// }
/// ```
public protocol Middleware: Sendable {
    /// Executes the middleware logic for a command.
    /// 
    /// - Parameters:
    ///   - command: The command being processed
    ///   - metadata: Metadata associated with the command execution
    ///   - next: The next handler in the chain (middleware or final handler)
    /// - Returns: The result from executing the command
    /// - Throws: Any errors that occur during execution
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result
}

/// Protocol for middleware that has an explicit priority.
/// 
/// Used in priority-based pipeline implementations to control
/// the order of middleware execution.
public protocol MiddlewarePriority {
    /// The priority value (lower numbers execute first)
    var priority: Int { get }
}

/// Standard middleware ordering priorities.
/// 
/// These values provide a consistent ordering for common middleware types.
/// Lower values execute earlier in the pipeline. Values are spaced to allow
/// insertion of custom middleware between standard types.
/// 
/// Example usage:
/// ```swift
/// pipeline.addMiddleware(authMiddleware, priority: MiddlewareOrder.authentication.rawValue)
/// pipeline.addMiddleware(validationMiddleware, priority: MiddlewareOrder.validation.rawValue)
/// ```
public enum MiddlewareOrder: Int, Sendable {
    // MARK: - Pre-Processing (0-99)
    
    /// Request ID generation and correlation
    case correlation = 10
    
    /// Request decompression (gzip, etc.)
    case decompression = 20
    
    /// Request decryption
    case decryption = 30
    
    /// Request deserialization
    case deserialization = 40
    
    // MARK: - Security (100-299)
    
    /// Authentication middleware (verifies identity)
    case authentication = 100
    
    /// Session validation and management
    case session = 120
    
    /// API key validation
    case apiKey = 140
    
    /// Token refresh and management
    case tokenRefresh = 160
    
    /// Authorization middleware (verifies permissions)
    case authorization = 200
    
    /// RBAC (Role-Based Access Control)
    case rbac = 220
    
    /// ABAC (Attribute-Based Access Control)
    case abac = 240
    
    /// Security headers and CORS
    case securityHeaders = 260
    
    /// IP whitelist/blacklist checking
    case ipFiltering = 280
    
    // MARK: - Validation & Sanitization (300-399)
    
    /// Input validation middleware
    case validation = 300
    
    /// Schema validation (JSON Schema, etc.)
    case schemaValidation = 320
    
    /// Input sanitization
    case sanitization = 340
    
    /// Business rule validation
    case businessRules = 360
    
    /// Data transformation and normalization
    case transformation = 380
    
    // MARK: - Traffic Control (400-499)
    
    /// Rate limiting middleware (prevents abuse)
    case rateLimiting = 400
    
    /// Request throttling
    case throttling = 420
    
    /// Circuit breaker pattern
    case circuitBreaker = 440
    
    /// Bulkhead isolation
    case bulkhead = 460
    
    /// Load balancing decisions
    case loadBalancing = 480
    
    // MARK: - Observability (500-599)
    
    /// Logging middleware (records execution)
    case logging = 500
    
    /// Audit logging for compliance
    case auditLogging = 520
    
    /// Distributed tracing
    case tracing = 540
    
    /// Performance monitoring
    case monitoring = 560
    
    /// Metrics collection
    case metrics = 580
    
    // MARK: - Enhancement (600-699)
    
    /// Response caching
    case caching = 600
    
    /// Feature flags and A/B testing
    case featureFlags = 620
    
    /// Content enrichment
    case enrichment = 640
    
    /// Localization and internationalization
    case localization = 660
    
    /// Response compression
    case compression = 680
    
    // MARK: - Error Handling (700-799)
    
    /// Error handling and recovery
    case errorHandling = 700
    
    /// Retry logic
    case retry = 720
    
    /// Fallback mechanisms
    case fallback = 740
    
    /// Error transformation
    case errorTransformation = 760
    
    /// Dead letter queue handling
    case deadLetter = 780
    
    // MARK: - Post-Processing (800-899)
    
    /// Response transformation
    case responseTransformation = 800
    
    /// Response encryption
    case encryption = 820
    
    /// Response signing
    case signing = 840
    
    /// Webhook notifications
    case webhooks = 860
    
    /// Event publishing
    case eventPublishing = 880
    
    // MARK: - Transaction Management (900-999)
    
    /// Transaction begin/commit/rollback
    case transaction = 900
    
    /// Saga orchestration
    case saga = 920
    
    /// Distributed transaction coordination
    case distributedTransaction = 940
    
    /// Compensation logic
    case compensation = 960
    
    /// Transaction logging
    case transactionLogging = 980
    
    // MARK: - Custom (1000+)
    
    /// Custom middleware (user-defined)
    case custom = 1000
    
    /// Testing and debugging middleware
    case testing = 2000
    
    /// Development-only middleware
    case development = 3000
}