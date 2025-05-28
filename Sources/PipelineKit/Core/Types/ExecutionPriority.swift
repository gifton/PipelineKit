import Foundation

/// Standard middleware execution priorities.
/// 
/// These values provide a consistent ordering for common middleware types.
/// Lower values execute earlier in the pipeline. Values are spaced to allow
/// insertion of custom middleware between standard types.
/// 
/// Example usage:
/// ```swift
/// pipeline.addMiddleware(authMiddleware, priority: ExecutionPriority.authentication.rawValue)
/// pipeline.addMiddleware(validationMiddleware, priority: ExecutionPriority.validation.rawValue)
/// ```
public enum ExecutionPriority: Int, Sendable {
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

// MARK: - Extensions

extension ExecutionPriority {
    /// Returns a descriptive category name for this execution priority.
    public var category: String {
        switch self.rawValue {
        case 0..<100:
            return "Pre-Processing"
        case 100..<300:
            return "Security"
        case 300..<400:
            return "Validation & Sanitization"
        case 400..<500:
            return "Traffic Control"
        case 500..<600:
            return "Observability"
        case 600..<700:
            return "Enhancement"
        case 700..<800:
            return "Error Handling"
        case 800..<900:
            return "Post-Processing"
        case 900..<1000:
            return "Transaction Management"
        default:
            return "Custom"
        }
    }
    
    /// Returns all execution priorities in a specific category.
    public static func category(_ category: MiddlewareCategory) -> [ExecutionPriority] {
        return allCases.filter { order in
            switch category {
            case .preProcessing:
                return order.rawValue < 100
            case .security:
                return order.rawValue >= 100 && order.rawValue < 300
            case .validationSanitization:
                return order.rawValue >= 300 && order.rawValue < 400
            case .trafficControl:
                return order.rawValue >= 400 && order.rawValue < 500
            case .observability:
                return order.rawValue >= 500 && order.rawValue < 600
            case .enhancement:
                return order.rawValue >= 600 && order.rawValue < 700
            case .errorHandling:
                return order.rawValue >= 700 && order.rawValue < 800
            case .postProcessing:
                return order.rawValue >= 800 && order.rawValue < 900
            case .transactionManagement:
                return order.rawValue >= 900 && order.rawValue < 1000
            case .custom:
                return order.rawValue >= 1000
            }
        }
    }
    
    /// Creates a custom priority value between two standard orders.
    /// 
    /// Example:
    /// ```swift
    /// let customPriority = ExecutionPriority.between(.authentication, and: .session)
    /// // Returns 110 (between 100 and 120)
    /// ```
    public static func between(_ first: ExecutionPriority, and second: ExecutionPriority) -> Int {
        let lower = min(first.rawValue, second.rawValue)
        let upper = max(first.rawValue, second.rawValue)
        return lower + (upper - lower) / 2
    }
    
    /// Creates a custom priority value just before the specified order.
    /// 
    /// Example:
    /// ```swift
    /// let customPriority = ExecutionPriority.before(.authentication)
    /// // Returns 99
    /// ```
    public static func before(_ order: ExecutionPriority) -> Int {
        order.rawValue - 1
    }
    
    /// Creates a custom priority value just after the specified order.
    /// 
    /// Example:
    /// ```swift
    /// let customPriority = ExecutionPriority.after(.authentication)
    /// // Returns 101
    /// ```
    public static func after(_ order: ExecutionPriority) -> Int {
        order.rawValue + 1
    }
}

/// Categories for grouping middleware types.
public enum MiddlewareCategory: String, CaseIterable, Sendable {
    case preProcessing = "Pre-Processing"
    case security = "Security"
    case validationSanitization = "Validation & Sanitization"
    case trafficControl = "Traffic Control"
    case observability = "Observability"
    case enhancement = "Enhancement"
    case errorHandling = "Error Handling"
    case postProcessing = "Post-Processing"
    case transactionManagement = "Transaction Management"
    case custom = "Custom"
}

// Make ExecutionPriority conform to CaseIterable
extension ExecutionPriority: CaseIterable {
    public static var allCases: [ExecutionPriority] {
        return [
            // Pre-Processing
            .correlation, .decompression, .decryption, .deserialization,
            
            // Security
            .authentication, .session, .apiKey, .tokenRefresh,
            .authorization, .rbac, .abac, .securityHeaders, .ipFiltering,
            
            // Validation & Sanitization
            .validation, .schemaValidation, .sanitization,
            .businessRules, .transformation,
            
            // Traffic Control
            .rateLimiting, .throttling, .circuitBreaker,
            .bulkhead, .loadBalancing,
            
            // Observability
            .logging, .auditLogging, .tracing, .monitoring, .metrics,
            
            // Enhancement
            .caching, .featureFlags, .enrichment,
            .localization, .compression,
            
            // Error Handling
            .errorHandling, .retry, .fallback,
            .errorTransformation, .deadLetter,
            
            // Post-Processing
            .responseTransformation, .encryption, .signing,
            .webhooks, .eventPublishing,
            
            // Transaction Management
            .transaction, .saga, .distributedTransaction,
            .compensation, .transactionLogging,
            
            // Custom
            .custom, .testing, .development
        ]
    }
}