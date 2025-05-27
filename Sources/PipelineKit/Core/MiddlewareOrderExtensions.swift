import Foundation

extension MiddlewareOrder {
    /// Returns a descriptive category name for this middleware order.
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
    
    /// Returns all middleware orders in a specific category.
    public static func category(_ category: MiddlewareCategory) -> [MiddlewareOrder] {
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
    /// let customPriority = MiddlewareOrder.between(.authentication, and: .session)
    /// // Returns 110 (between 100 and 120)
    /// ```
    public static func between(_ first: MiddlewareOrder, and second: MiddlewareOrder) -> Int {
        let lower = min(first.rawValue, second.rawValue)
        let upper = max(first.rawValue, second.rawValue)
        return lower + (upper - lower) / 2
    }
    
    /// Creates a custom priority value just before the specified order.
    /// 
    /// Example:
    /// ```swift
    /// let customPriority = MiddlewareOrder.before(.authentication)
    /// // Returns 99
    /// ```
    public static func before(_ order: MiddlewareOrder) -> Int {
        order.rawValue - 1
    }
    
    /// Creates a custom priority value just after the specified order.
    /// 
    /// Example:
    /// ```swift
    /// let customPriority = MiddlewareOrder.after(.authentication)
    /// // Returns 101
    /// ```
    public static func after(_ order: MiddlewareOrder) -> Int {
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

// Make MiddlewareOrder conform to CaseIterable
extension MiddlewareOrder: CaseIterable {
    public static var allCases: [MiddlewareOrder] {
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

/// A builder for creating middleware with proper ordering.
public struct MiddlewareOrderBuilder {
    private var middlewares: [(any Middleware, Int)] = []
    
    public init() {}
    
    /// Adds middleware with a standard order.
    public mutating func add(
        _ middleware: any Middleware,
        order: MiddlewareOrder
    ) {
        middlewares.append((middleware, order.rawValue))
    }
    
    /// Adds middleware with a custom priority.
    public mutating func add(
        _ middleware: any Middleware,
        priority: Int
    ) {
        middlewares.append((middleware, priority))
    }
    
    /// Adds middleware between two standard orders.
    public mutating func add(
        _ middleware: any Middleware,
        between first: MiddlewareOrder,
        and second: MiddlewareOrder
    ) {
        let priority = MiddlewareOrder.between(first, and: second)
        middlewares.append((middleware, priority))
    }
    
    /// Returns middleware sorted by priority.
    public func build() -> [(any Middleware, Int)] {
        return middlewares.sorted { $0.1 < $1.1 }
    }
}
