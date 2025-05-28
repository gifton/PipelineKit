import Foundation

/// Middleware execution order with raw integer values for fine-grained control
public struct MiddlewareOrder: RawRepresentable, Comparable, Sendable {
    public let rawValue: Int
    
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    public init?(_ rawValue: Int) {
        self.init(rawValue: rawValue)
    }
    
    public static func < (lhs: MiddlewareOrder, rhs: MiddlewareOrder) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Standard Middleware Orders

public extension MiddlewareOrder {
    // MARK: - Pre-Processing (0-99)
    
    /// Request correlation and ID generation
    static let correlation = MiddlewareOrder(rawValue: 10)
    
    /// Request tracking and observability setup  
    static let observability = MiddlewareOrder(rawValue: 15)
    
    /// Performance tracking setup
    static let performanceTracking = MiddlewareOrder(rawValue: 5)
    
    /// Request decompression
    static let decompression = MiddlewareOrder(rawValue: 20)
    
    /// Request decryption
    static let decryption = MiddlewareOrder(rawValue: 30)
    
    /// Distributed tracing setup
    static let distributedTracing = MiddlewareOrder(rawValue: 25)
    
    // MARK: - Security (100-299)
    
    /// Authentication middleware
    static let authentication = MiddlewareOrder(rawValue: 100)
    
    /// Session validation
    static let session = MiddlewareOrder(rawValue: 120)
    
    /// Authorization middleware
    static let authorization = MiddlewareOrder(rawValue: 200)
    
    /// Security headers
    static let securityHeaders = MiddlewareOrder(rawValue: 260)
    
    // MARK: - Validation & Sanitization (300-399)
    
    /// Input validation
    static let validation = MiddlewareOrder(rawValue: 300)
    
    /// Input sanitization
    static let sanitization = MiddlewareOrder(rawValue: 310)
    
    /// Business rules validation
    static let businessRules = MiddlewareOrder(rawValue: 360)
    
    // MARK: - Traffic Control (400-499)
    
    /// Rate limiting
    static let rateLimiting = MiddlewareOrder(rawValue: 400)
    
    /// Circuit breaker
    static let circuitBreaker = MiddlewareOrder(rawValue: 440)
    
    /// Load balancing
    static let loadBalancing = MiddlewareOrder(rawValue: 480)
    
    // MARK: - Enhancement (600-699)
    
    /// Response caching
    static let caching = MiddlewareOrder(rawValue: 600)
    
    /// Feature flags
    static let featureFlags = MiddlewareOrder(rawValue: 620)
    
    /// Content enrichment
    static let enrichment = MiddlewareOrder(rawValue: 640)
    
    // MARK: - Post-Processing (800-899)
    
    /// Audit logging
    static let auditLogging = MiddlewareOrder(rawValue: 800)
    
    /// Custom event emission
    static let customEventEmitter = MiddlewareOrder(rawValue: 850)
    
    /// Response encryption
    static let encryption = MiddlewareOrder(rawValue: 820)
    
    /// Event publishing
    static let eventPublishing = MiddlewareOrder(rawValue: 880)
    
    // MARK: - Custom Orders
    
    /// Custom middleware base
    static let custom = MiddlewareOrder(rawValue: 1000)
    
    /// Creates a custom order with the specified value
    static func custom(_ value: Int) -> MiddlewareOrder {
        return MiddlewareOrder(rawValue: value)
    }
    
    /// Creates an order between two existing orders
    static func between(_ first: MiddlewareOrder, _ second: MiddlewareOrder) -> MiddlewareOrder {
        let lower = min(first.rawValue, second.rawValue)
        let upper = max(first.rawValue, second.rawValue)
        return MiddlewareOrder(rawValue: lower + (upper - lower) / 2)
    }
    
    /// Creates an order just before another order
    static func before(_ order: MiddlewareOrder) -> MiddlewareOrder {
        return MiddlewareOrder(rawValue: order.rawValue - 1)
    }
    
    /// Creates an order just after another order
    static func after(_ order: MiddlewareOrder) -> MiddlewareOrder {
        return MiddlewareOrder(rawValue: order.rawValue + 1)
    }
}

// MARK: - Category Helpers

public extension MiddlewareOrder {
    /// Returns the category name for this middleware order
    var category: String {
        switch rawValue {
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
    
    /// Returns true if this order is in the specified range
    func isInCategory(_ category: MiddlewareCategory) -> Bool {
        switch category {
        case .preProcessing:
            return rawValue >= 0 && rawValue < 100
        case .security:
            return rawValue >= 100 && rawValue < 300
        case .validationSanitization:
            return rawValue >= 300 && rawValue < 400
        case .trafficControl:
            return rawValue >= 400 && rawValue < 500
        case .observability:
            return rawValue >= 500 && rawValue < 600
        case .enhancement:
            return rawValue >= 600 && rawValue < 700
        case .errorHandling:
            return rawValue >= 700 && rawValue < 800
        case .postProcessing:
            return rawValue >= 800 && rawValue < 900
        case .transactionManagement:
            return rawValue >= 900 && rawValue < 1000
        case .custom:
            return rawValue >= 1000
        }
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension MiddlewareOrder: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(rawValue: value)
    }
}

// MARK: - CustomStringConvertible

extension MiddlewareOrder: CustomStringConvertible {
    public var description: String {
        return "\(category)(\(rawValue))"
    }
}