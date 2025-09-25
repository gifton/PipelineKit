import Foundation

/// Unified error type for all pipeline operations.
/// 
/// This consolidates all error types across the pipeline framework into a single,
/// comprehensive error enum with nested categorization for specific error types.
public enum PipelineError: Error, Sendable, LocalizedError {
    // MARK: - Pipeline Execution Errors
    
    /// No handler is registered for the command type
    case handlerNotFound(commandType: String)
    
    /// Command execution failed
    case executionFailed(message: String, context: ErrorContext?)
    
    /// Middleware execution failed
    case middlewareError(middleware: String, message: String, context: ErrorContext?)
    
    /// Maximum middleware depth exceeded
    case maxDepthExceeded(depth: Int, max: Int)
    
    /// Operation timed out
    case timeout(duration: TimeInterval, context: ErrorContext?)
    
    /// Retry attempts exhausted
    case retryExhausted(attempts: Int, lastError: Error?)
    
    /// Command context is missing
    case contextMissing
    
    /// Pipeline not configured properly
    case pipelineNotConfigured(reason: String)
    
    /// Operation was cancelled
    case cancelled(context: String?)
    
    // MARK: - Validation Errors
    
    /// Validation failed for a command
    case validation(field: String?, reason: ValidationReason)
    
    // MARK: - Authorization Errors
    
    /// Authorization check failed
    case authorization(reason: AuthorizationReason)
    
    // MARK: - Security Errors
    
    /// Security policy violation
    case securityPolicy(reason: SecurityPolicyReason)
    
    /// Encryption/decryption error
    case encryption(reason: EncryptionReason)
    
    // MARK: - Rate Limiting
    
    /// Rate limit exceeded
    case rateLimitExceeded(limit: Int, resetTime: Date?, retryAfter: TimeInterval?)
    
    // MARK: - Caching Errors
    
    /// Cache operation failed
    case cache(reason: CacheReason)
    
    // MARK: - Parallel Execution
    
    /// Parallel execution failed with multiple errors
    case parallelExecutionFailed(errors: [Error])
    
    // MARK: - Context Errors
    
    /// Context-related errors
    case context(reason: ContextReason)
    
    // MARK: - Circuit Breaker
    
    /// Circuit breaker is open
    case circuitBreakerOpen(resetTime: Date?)
    
    // MARK: - Authentication
    
    /// Authentication failed
    case authentication(required: Bool)
    
    // MARK: - Resource Management
    
    /// Resource-related errors
    case resource(reason: ResourceReason)
    
    // MARK: - Resilience
    
    /// Resilience-related errors  
    case resilience(reason: ResilienceReason)
    
    // MARK: - Observation/Monitoring
    
    /// Observer or monitoring errors
    case observer(reason: String)
    
    // MARK: - Optimization
    
    /// Optimization-related errors
    case optimization(reason: String)
    
    // MARK: - Export/Serialization
    
    /// Export or serialization errors
    case export(reason: ExportReason)
    
    // MARK: - Test Support
    
    /// Test-specific errors (only in test targets)
    case test(reason: String)
    
    // MARK: - Back Pressure
    
    /// Back pressure and capacity management errors
    case backPressure(reason: BackPressureReason)
    
    /// Command was rejected by bulkhead middleware
    case bulkheadRejected(reason: String)
    
    /// Command timed out in bulkhead queue
    case bulkheadTimeout(timeout: TimeInterval, queueTime: TimeInterval)
    
    // MARK: - Simulation
    
    /// Simulation and stress testing errors
    case simulation(reason: SimulationReason)
    
    // MARK: - NextGuard Safety Errors
    
    /// Next closure was called multiple times
    case nextAlreadyCalled
    
    /// Next closure is currently executing (concurrent call attempt)
    case nextCurrentlyExecuting
    
    /// Next closure was never called (debug only)
    case nextNeverCalled
    
    // MARK: - Generic Wrapped Error
    
    /// Wraps any other error with optional context
    case wrapped(Error, context: ErrorContext?)
    
    // MARK: - Nested Types
    
    /// Validation failure reasons
    public enum ValidationReason: Sendable {
        case invalidEmail
        case weakPassword
        case missingRequired
        case invalidFormat(expected: String)
        case tooLong(field: String, max: Int)
        case tooShort(field: String, min: Int)
        case invalidCharacters(field: String)
        case outOfRange(field: String, min: Double?, max: Double?)
        case custom(String)
    }
    
    /// Authorization failure reasons
    public enum AuthorizationReason: Sendable {
        case insufficientPermissions(required: [String], actual: [String])
        case invalidCredentials
        case tokenExpired
        case accessDenied(resource: String)
        case roleRequired(role: String)
        case custom(String)
    }
    
    /// Encryption failure reasons
    public enum EncryptionReason: Sendable {
        case encryptionFailed(String)
        case decryptionFailed(String)
        case keyNotFound(identifier: String)
        case invalidKey
        case algorithmNotSupported(String)
    }
    
    /// Cache failure reasons
    public enum CacheReason: Sendable {
        case serializationFailed(String)
        case deserializationFailed(String)
        case storageFull
        case expired
        case invalidKey(String)
        case storageError(String)
    }
    
    /// Context failure reasons
    public enum ContextReason: Sendable {
        case missingRequiredValue(String)
        case typeMismatch(expected: String, actual: String)
        case accessDenied(String)
        case invalidState(String)
    }
    
    /// Resource failure reasons
    public enum ResourceReason: Sendable {
        case exhausted(resource: String)
        case unavailable(resource: String)
        case limitExceeded(resource: String, limit: Int)
        case allocationFailed(String)
        case memoryPressure
        case cpuOverload
        case notFound(resourceId: UUID)
    }
    
    /// Resilience failure reasons
    public enum ResilienceReason: Sendable {
        case circuitBreakerOpen
        case retryExhausted(attempts: Int)
        case fallbackFailed(String)
        case bulkheadFull
        case timeoutExceeded
    }
    
    /// Export failure reasons
    public enum ExportReason: Sendable {
        case formatNotSupported(String)
        case serializationFailed(String)
        case ioError(String)
        case invalidData(String)
        case exporterClosed
    }
    
    /// Security policy failure reasons
    public enum SecurityPolicyReason: Sendable {
        case commandTooLarge(size: Int, maxSize: Int)
        case stringTooLong(field: String, length: Int, maxLength: Int)
        case invalidCharacters(field: String, invalidChars: String)
        case htmlContentNotAllowed(field: String)
        case validationFailed(reason: String)
    }
    
    /// Back pressure failure reasons
    public enum BackPressureReason: Sendable {
        case queueFull(current: Int, limit: Int)
        case timeout(duration: TimeInterval)
        case commandDropped(reason: String)
        case memoryPressure
    }
    
    /// Simulation failure reasons
    public enum SimulationReason: Sendable {
        case cpu(CPUReason)
        case memory(MemoryReason)
        case concurrency(ConcurrencyReason)
        case exhaustion(ExhaustionReason)
        case scenario(ScenarioReason)
    }
    
    /// CPU simulation failure reasons
    public enum CPUReason: Sendable {
        case invalidState(current: String, expected: String)
        case safetyLimitExceeded(requested: Int, reason: String)
    }
    
    /// Memory simulation failure reasons
    public enum MemoryReason: Sendable {
        case invalidState(current: String, expected: String)
        case safetyLimitExceeded(requested: Int, reason: String)
        case allocationFailed(size: Int, error: String)
    }
    
    /// Concurrency simulation failure reasons
    public enum ConcurrencyReason: Sendable {
        case invalidState(current: String, expected: String)
        case safetyLimitExceeded(requested: Int, reason: String)
        case resourceExhausted(type: String)
    }
    
    /// Resource exhaustion failure reasons
    public enum ExhaustionReason: Sendable {
        case invalidState(current: String, expected: String)
        case safetyLimitExceeded(requested: Int, reason: String)
        case allocationFailed(type: String, reason: String)
        case invalidAmount(reason: String)
        case unsupportedResource(type: String)
        case exhaustionFailed(reason: String)
    }
    
    /// Scenario failure reasons
    public enum ScenarioReason: Sendable {
        case alreadyRunning
        case invalidConfiguration(reason: String)
        case executionFailed(reason: String)
        case safetyViolation(reason: String)
    }
    
    /// Additional context for errors
    public struct ErrorContext: Sendable {
        public let commandType: String
        public let middlewareType: String?
        public let correlationID: String?
        public let userID: String?
        public let additionalInfo: [String: String]
        public let timestamp: Date
        public let stackTrace: [String]?
        
        public init(
            commandType: String,
            middlewareType: String? = nil,
            correlationID: String? = nil,
            userID: String? = nil,
            additionalInfo: [String: String] = [:],
            timestamp: Date = Date(),
            stackTrace: [String]? = nil
        ) {
            self.commandType = commandType
            self.middlewareType = middlewareType
            self.correlationID = correlationID
            self.userID = userID
            self.additionalInfo = additionalInfo
            self.timestamp = timestamp
            self.stackTrace = stackTrace ?? Thread.callStackSymbols.map { String($0) }
        }
    }
    
    // MARK: - LocalizedError Implementation
    
    public var errorDescription: String? {
        switch self {
        case .handlerNotFound(let commandType):
            return "No handler registered for command type: \(commandType)"
            
        case let .executionFailed(message, context):
            if let context = context {
                return "Command execution failed for \(context.commandType): \(message)"
            }
            return "Command execution failed: \(message)"
            
        case let .middlewareError(middleware, message, _):
            return "Middleware '\(middleware)' error: \(message)"
            
        case let .maxDepthExceeded(depth, max):
            return "Maximum middleware depth exceeded: \(depth) (max: \(max))"
            
        case let .timeout(duration, context):
            if let context = context {
                return "Operation '\(context.commandType)' timed out after \(duration) seconds"
            }
            return "Operation timed out after \(duration) seconds"
            
        case let .retryExhausted(attempts, lastError):
            var message = "Retry exhausted after \(attempts) attempts"
            if let error = lastError {
                message += ": \(error.localizedDescription)"
            }
            return message
            
        case .contextMissing:
            return "Command context is missing"
            
        case .pipelineNotConfigured(let reason):
            return "Pipeline not configured: \(reason)"
            
        case .cancelled(let context):
            if let context = context {
                return "Operation cancelled: \(context)"
            }
            return "Operation cancelled"
            
        case let .validation(field, reason):
            let fieldPrefix = field.map { "Field '\($0)': " } ?? ""
            return fieldPrefix + validationReasonDescription(reason)
            
        case .authorization(let reason):
            return authorizationReasonDescription(reason)
            
        case .securityPolicy(let reason):
            return securityPolicyReasonDescription(reason)
            
        case .encryption(let reason):
            return encryptionReasonDescription(reason)
            
        case let .rateLimitExceeded(limit, resetTime, retryAfter):
            var message = "Rate limit exceeded: \(limit) requests allowed"
            if let resetTime = resetTime {
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                message += ", resets at \(formatter.string(from: resetTime))"
            }
            if let retryAfter = retryAfter {
                message += ", retry after \(Int(retryAfter)) seconds"
            }
            return message
            
        case .cache(let reason):
            return cacheReasonDescription(reason)
            
        case .parallelExecutionFailed(let errors):
            return "Parallel execution failed with \(errors.count) errors"
            
        case .context(let reason):
            return contextReasonDescription(reason)
            
        case .circuitBreakerOpen(let resetTime):
            if let resetTime = resetTime {
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                return "Circuit breaker is open, resets at \(formatter.string(from: resetTime))"
            }
            return "Circuit breaker is open"
            
        case .authentication(let required):
            return required ? "Authentication required" : "Authentication failed"
            
        case .resource(let reason):
            return resourceReasonDescription(reason)
            
        case .resilience(let reason):
            return resilienceReasonDescription(reason)
            
        case .observer(let reason):
            return "Observer error: \(reason)"
            
        case .optimization(let reason):
            return "Optimization error: \(reason)"
            
        case .export(let reason):
            return exportReasonDescription(reason)
            
        case .test(let reason):
            return "Test error: \(reason)"
            
        case .backPressure(let reason):
            return backPressureReasonDescription(reason)
            
        case .bulkheadRejected(let reason):
            return "Bulkhead rejected: \(reason)"
            
        case let .bulkheadTimeout(timeout, queueTime):
            return "Bulkhead timeout after \(queueTime)s (limit: \(timeout)s)"
            
        case .simulation(let reason):
            return simulationReasonDescription(reason)
            
        case .nextAlreadyCalled:
            return "Middleware next() closure was called multiple times (must be called exactly once)"
            
        case .nextCurrentlyExecuting:
            return "Middleware next() closure is currently executing (concurrent calls not allowed)"
            
        case .nextNeverCalled:
            return "Middleware completed without calling next() closure"
            
        case let .wrapped(error, context):
            if let context = context {
                return "Error in \(context.commandType): \(error.localizedDescription)"
            }
            return error.localizedDescription
        }
    }
    
    // MARK: - Private Helpers
    
    private func validationReasonDescription(_ reason: ValidationReason) -> String {
        switch reason {
        case .invalidEmail:
            return "Invalid email address format"
        case .weakPassword:
            return "Password does not meet security requirements"
        case .missingRequired:
            return "Required field is missing"
        case .invalidFormat(let expected):
            return "Invalid format, expected: \(expected)"
        case let .tooLong(field, max):
            return "\(field) exceeds maximum length of \(max)"
        case let .tooShort(field, min):
            return "\(field) is shorter than minimum length of \(min)"
        case .invalidCharacters(let field):
            return "\(field) contains invalid characters"
        case let .outOfRange(field, min, max):
            var message = "\(field) is out of range"
            if let min = min, let max = max {
                message += " (\(min)-\(max))"
            } else if let min = min {
                message += " (minimum: \(min))"
            } else if let max = max {
                message += " (maximum: \(max))"
            }
            return message
        case .custom(let message):
            return message
        }
    }
    
    private func authorizationReasonDescription(_ reason: AuthorizationReason) -> String {
        switch reason {
        case let .insufficientPermissions(required, actual):
            return "Insufficient permissions. Required: \(required.joined(separator: ", ")), Actual: \(actual.joined(separator: ", "))"
        case .invalidCredentials:
            return "Invalid credentials provided"
        case .tokenExpired:
            return "Authentication token has expired"
        case .accessDenied(let resource):
            return "Access denied to resource: \(resource)"
        case .roleRequired(let role):
            return "Role '\(role)' is required"
        case .custom(let message):
            return message
        }
    }
    
    private func encryptionReasonDescription(_ reason: EncryptionReason) -> String {
        switch reason {
        case .encryptionFailed(let message):
            return "Encryption failed: \(message)"
        case .decryptionFailed(let message):
            return "Decryption failed: \(message)"
        case .keyNotFound(let identifier):
            return "Encryption key not found: \(identifier)"
        case .invalidKey:
            return "Invalid encryption key"
        case .algorithmNotSupported(let algorithm):
            return "Encryption algorithm not supported: \(algorithm)"
        }
    }
    
    private func cacheReasonDescription(_ reason: CacheReason) -> String {
        switch reason {
        case .serializationFailed(let message):
            return "Cache serialization failed: \(message)"
        case .deserializationFailed(let message):
            return "Cache deserialization failed: \(message)"
        case .storageFull:
            return "Cache storage is full"
        case .expired:
            return "Cache entry has expired"
        case .invalidKey(let key):
            return "Invalid cache key: \(key)"
        case .storageError(let message):
            return "Cache storage error: \(message)"
        }
    }
    
    private func contextReasonDescription(_ reason: ContextReason) -> String {
        switch reason {
        case .missingRequiredValue(let key):
            return "Missing required context value: \(key)"
        case let .typeMismatch(expected, actual):
            return "Context type mismatch. Expected: \(expected), Actual: \(actual)"
        case .accessDenied(let key):
            return "Access denied to context value: \(key)"
        case .invalidState(let message):
            return "Invalid context state: \(message)"
        }
    }
    
    private func resourceReasonDescription(_ reason: ResourceReason) -> String {
        switch reason {
        case .exhausted(let resource):
            return "Resource exhausted: \(resource)"
        case .unavailable(let resource):
            return "Resource unavailable: \(resource)"
        case let .limitExceeded(resource, limit):
            return "Resource limit exceeded for \(resource): \(limit)"
        case .allocationFailed(let message):
            return "Resource allocation failed: \(message)"
        case .memoryPressure:
            return "System under memory pressure"
        case .cpuOverload:
            return "CPU overload detected"
        case .notFound(let resourceId):
            return "Resource not found: \(resourceId)"
        }
    }
    
    private func resilienceReasonDescription(_ reason: ResilienceReason) -> String {
        switch reason {
        case .circuitBreakerOpen:
            return "Circuit breaker is open"
        case .retryExhausted(let attempts):
            return "Retry exhausted after \(attempts) attempts"
        case .fallbackFailed(let message):
            return "Fallback failed: \(message)"
        case .bulkheadFull:
            return "Bulkhead is full"
        case .timeoutExceeded:
            return "Timeout exceeded"
        }
    }
    
    private func exportReasonDescription(_ reason: ExportReason) -> String {
        switch reason {
        case .formatNotSupported(let format):
            return "Export format not supported: \(format)"
        case .serializationFailed(let message):
            return "Export serialization failed: \(message)"
        case .ioError(let message):
            return "Export I/O error: \(message)"
        case .invalidData(let message):
            return "Invalid export data: \(message)"
        case .exporterClosed:
            return "Exporter has been closed"
        }
    }
    
    private func securityPolicyReasonDescription(_ reason: SecurityPolicyReason) -> String {
        switch reason {
        case let .commandTooLarge(size, maxSize):
            return "Command size \(size) bytes exceeds maximum allowed size of \(maxSize) bytes"
        case let .stringTooLong(field, length, maxLength):
            return "Field '\(field)' length \(length) exceeds maximum allowed length of \(maxLength)"
        case let .invalidCharacters(field, invalidChars):
            return "Field '\(field)' contains invalid characters: \(invalidChars)"
        case .htmlContentNotAllowed(let field):
            return "Field '\(field)' contains HTML content which is not allowed"
        case .validationFailed(let reason):
            return "Security policy validation failed: \(reason)"
        }
    }
    
    private func backPressureReasonDescription(_ reason: BackPressureReason) -> String {
        switch reason {
        case let .queueFull(current, limit):
            return "Pipeline queue is full: \(current) commands (limit: \(limit))"
        case .timeout(let duration):
            return "Timeout occurred while waiting for capacity: \(duration) seconds"
        case .commandDropped(let reason):
            return "Command was dropped: \(reason)"
        case .memoryPressure:
            return "Memory pressure exceeded configured limits"
        }
    }
    
    private func simulationReasonDescription(_ reason: SimulationReason) -> String {
        switch reason {
        case .cpu(let cpuReason):
            return cpuReasonDescription(cpuReason)
        case .memory(let memoryReason):
            return memoryReasonDescription(memoryReason)
        case .concurrency(let concurrencyReason):
            return concurrencyReasonDescription(concurrencyReason)
        case .exhaustion(let exhaustionReason):
            return exhaustionReasonDescription(exhaustionReason)
        case .scenario(let scenarioReason):
            return scenarioReasonDescription(scenarioReason)
        }
    }
    
    private func cpuReasonDescription(_ reason: CPUReason) -> String {
        switch reason {
        case let .invalidState(current, expected):
            return "Invalid CPU simulator state: \(current), expected \(expected)"
        case let .safetyLimitExceeded(requested, reason):
            return "CPU safety limit exceeded: requested \(requested)% - \(reason)"
        }
    }
    
    private func memoryReasonDescription(_ reason: MemoryReason) -> String {
        switch reason {
        case let .invalidState(current, expected):
            return "Invalid memory simulator state: \(current), expected \(expected)"
        case let .safetyLimitExceeded(requested, reason):
            return "Memory safety limit exceeded: requested \(requested) bytes - \(reason)"
        case let .allocationFailed(size, error):
            return "Failed to allocate \(size) bytes: \(error)"
        }
    }
    
    private func concurrencyReasonDescription(_ reason: ConcurrencyReason) -> String {
        switch reason {
        case let .invalidState(current, expected):
            return "Invalid concurrency stressor state: \(current), expected \(expected)"
        case let .safetyLimitExceeded(requested, reason):
            return "Concurrency safety limit exceeded: requested \(requested) - \(reason)"
        case .resourceExhausted(let type):
            return "Concurrency resource exhausted: \(type)"
        }
    }
    
    private func exhaustionReasonDescription(_ reason: ExhaustionReason) -> String {
        switch reason {
        case let .invalidState(current, expected):
            return "Invalid exhauster state: \(current), expected \(expected)"
        case let .safetyLimitExceeded(requested, reason):
            return "Safety limit exceeded: requested \(requested) - \(reason)"
        case let .allocationFailed(type, reason):
            return "Failed to allocate \(type): \(reason)"
        case .invalidAmount(let reason):
            return "Invalid amount specification: \(reason)"
        case .unsupportedResource(let type):
            return "Unsupported resource type: \(type)"
        case .exhaustionFailed(let reason):
            return "Resource exhaustion failed: \(reason)"
        }
    }
    
    private func scenarioReasonDescription(_ reason: ScenarioReason) -> String {
        switch reason {
        case .alreadyRunning:
            return "A scenario is already running"
        case .invalidConfiguration(let reason):
            return "Invalid scenario configuration: \(reason)"
        case .executionFailed(let reason):
            return "Scenario execution failed: \(reason)"
        case .safetyViolation(let reason):
            return "Safety violation detected: \(reason)"
        }
    }
}

// MARK: - Error Analysis Extensions

public extension PipelineError {
    /// Whether this error is retryable
    var isRetryable: Bool {
        switch self {
        case .timeout, .rateLimitExceeded, .circuitBreakerOpen:
            return true
        case .resource(let reason):
            switch reason {
            case .memoryPressure, .cpuOverload:
                return true
            default:
                return false
            }
        case .resilience(let reason):
            switch reason {
            case .bulkheadFull, .timeoutExceeded:
                return true
            default:
                return false
            }
        case .wrapped(let error, _):
            // Check if wrapped error is retryable
            return (error as? PipelineError)?.isRetryable ?? false
        default:
            return false
        }
    }
    
    /// Whether this error is a security-related error
    var isSecurityError: Bool {
        switch self {
        case .authorization, .securityPolicy, .encryption, .authentication:
            return true
        case .context(let reason):
            if case .accessDenied = reason {
                return true
            }
            return false
        default:
            return false
        }
    }
    
    /// Whether this error represents a cancellation
    var isCancellation: Bool {
        switch self {
        case .cancelled:
            return true
        default:
            return false
        }
    }
    
    /// Extract error context if available
    var context: ErrorContext? {
        switch self {
        case .executionFailed(_, let context),
             .middlewareError(_, _, let context),
             .timeout(_, let context),
             .wrapped(_, let context):
            return context
        default:
            return nil
        }
    }
}


// MARK: - Convenience Factory Methods

public extension PipelineError {
    /// Creates an execution failed error with command context
    static func executionFailed<C: Command>(
        _ message: String,
        command: C,
        middleware: (any Middleware)? = nil,
        correlationID: String? = nil,
        userID: String? = nil
    ) -> PipelineError {
        let context = ErrorContext(
            commandType: String(describing: C.self),
            middlewareType: middleware.map { String(describing: type(of: $0)) },
            correlationID: correlationID,
            userID: userID
        )
        return .executionFailed(message: message, context: context)
    }
    
    /// Creates a timeout error with command context
    static func timeout<C: Command>(
        duration: TimeInterval,
        command: C,
        middleware: (any Middleware)? = nil
    ) -> PipelineError {
        let context = ErrorContext(
            commandType: String(describing: C.self),
            middlewareType: middleware.map { String(describing: type(of: $0)) }
        )
        return .timeout(duration: duration, context: context)
    }
}
