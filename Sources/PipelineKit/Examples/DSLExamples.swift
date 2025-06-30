import Foundation

// MARK: - DSL Examples

/// Comprehensive examples demonstrating PipelineKit's DSL capabilities
public enum DSLExamples {
    
    // MARK: - E-commerce Order Processing Example
    
    /// Demonstrates a real-world e-commerce order processing pipeline using DSL
    public static func ecommerceOrderPipeline() async throws {
        // Define order command and handler
        struct ProcessOrderCommand: Command {
            typealias Result = OrderResult
            
            let orderId: String
            let customerId: String
            let items: [OrderItem]
            let paymentMethod: PaymentMethod
            let shippingAddress: Address
        }
        
        struct OrderResult {
            let orderId: String
            let status: OrderStatus
            let trackingNumber: String?
            let estimatedDelivery: Date?
        }
        
        struct OrderItem {
            let productId: String
            let quantity: Int
            let price: Decimal
        }
        
        enum PaymentMethod {
            case creditCard(last4: String)
            case paypal(email: String)
            case applePay
        }
        
        struct Address {
            let street: String
            let city: String
            let state: String
            let zipCode: String
            let country: String
        }
        
        enum OrderStatus {
            case pending
            case processing
            case shipped
            case delivered
            case cancelled
            case failed
        }
        
        final class OrderHandler: CommandHandler {
            func handle(_ command: ProcessOrderCommand) async throws -> OrderResult {
                // Simulate order processing
                return OrderResult(
                    orderId: command.orderId,
                    status: .processing,
                    trackingNumber: "TRK-\(UUID().uuidString.prefix(8))",
                    estimatedDelivery: Date().addingTimeInterval(3 * 24 * 60 * 60) // 3 days
                )
            }
        }
        
        // Feature flags and configuration
        let isBlackFriday = false
        let isPrimeCustomer = true
        let maintenanceMode = false
        
        // Build the pipeline using DSL
        let pipeline = try await CreatePipeline(handler: OrderHandler()) {
            // Maintenance mode check
            if maintenanceMode {
                MaintenanceModeMiddleware()
                    .order(.authentication)
            }
            
            // Security and rate limiting
            MiddlewareGroup(order: .authentication) {
                ExampleMiddleware("RateLimiting", priority: .authentication)
                    .when { !isPrimeCustomer }
                
                ExampleMiddleware("SecurityHeaders", priority: .authentication)
                ExampleMiddleware("FraudDetection", priority: .authentication)
                    .timeout(5.0)
            }
            
            // Authentication and authorization
            ExampleMiddleware("Authentication", priority: .authentication)
                .order(.authentication)
            
            ExampleMiddleware("Authorization", priority: .authorization)
                .order(.authorization)
            
            // Input validation
            MiddlewareGroup(order: .validation) {
                ExampleMiddleware("OrderValidation", priority: .validation)
                ExampleMiddleware("AddressValidation", priority: .validation)
                ExampleMiddleware("PaymentValidation", priority: .validation)
                
                // Special validation for high-traffic events
                if isBlackFriday {
                    ExampleMiddleware("BlackFridayLimits", priority: .validation)
                }
            }
            
            // Inventory and pricing checks with retry
            ExampleMiddleware("InventoryCheck", priority: .businessRules)
                .retry(maxAttempts: 3, strategy: .exponentialBackoff(base: 0.5))
            
            ExampleMiddleware("PricingCalculation", priority: .businessRules)
                .when { !isPrimeCustomer || isBlackFriday }
            
            // Payment processing with timeout and retry
            ExampleMiddleware("PaymentProcessing", priority: .transaction)
                .retry(maxAttempts: 3, strategy: .exponentialBackoff())
            
            // Conditional shipping options
            if isPrimeCustomer {
                ExampleMiddleware("PrimeShipping", priority: .enrichment)
            } else {
                ExampleMiddleware("StandardShipping", priority: .enrichment)
            }
            
            // Parallel post-processing tasks
            ParallelMiddleware(
                ExampleMiddleware("EmailNotification", priority: .eventPublishing),
                ExampleMiddleware("SMSNotification", priority: .eventPublishing),
                ExampleMiddleware("InventoryUpdate", priority: .transaction),
                ExampleMiddleware("OrderAnalytics", priority: .metrics),
                ExampleMiddleware("LoyaltyPoints", priority: .enrichment)
            )
            
            // Monitoring and logging
            MiddlewareGroup(order: .monitoring) {
                ExampleMiddleware("MetricsCollection", priority: .monitoring)
                ExampleMiddleware("AuditLogging", priority: .monitoring)
                ExampleMiddleware("PerformanceTracing", priority: .monitoring)
                    .when { ProcessInfo.processInfo.environment["ENABLE_TRACING"] == "true" }
            }
        }
        
        // Example usage
        let command = ProcessOrderCommand(
            orderId: "ORD-12345",
            customerId: "CUST-67890",
            items: [
                OrderItem(productId: "PROD-001", quantity: 2, price: 29.99),
                OrderItem(productId: "PROD-002", quantity: 1, price: 49.99)
            ],
            paymentMethod: .creditCard(last4: "1234"),
            shippingAddress: Address(
                street: "123 Main St",
                city: "San Francisco",
                state: "CA",
                zipCode: "94105",
                country: "USA"
            )
        )
        
        let context = CommandContext(metadata: StandardCommandMetadata())
        let result = try await pipeline.execute(command, context: context)
        print("Order processed: \(result.orderId) - Status: \(result.status)")
    }
    
    // MARK: - API Gateway Example
    
    /// Demonstrates an API gateway pipeline with authentication, rate limiting, and caching
    public static func apiGatewayPipeline() async throws {
        struct APIRequest: Command {
            typealias Result = APIResponse
            
            let method: HTTPMethod
            let path: String
            let headers: [String: String]
            let body: Data?
            let queryParams: [String: String]
        }
        
        struct APIResponse {
            let statusCode: Int
            let headers: [String: String]
            let body: Data?
        }
        
        enum HTTPMethod {
            case get, post, put, delete, patch
        }
        
        final class APIGatewayHandler: CommandHandler {
            func handle(_ command: APIRequest) async throws -> APIResponse {
                // Route to appropriate backend service
                return APIResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: "{}".data(using: .utf8)
                )
            }
        }
        
        // Configuration
        let enableCaching = true
        let debugMode = false
        let apiVersion = "v2"
        
        // Build API gateway pipeline
        let pipeline = try await CreatePipeline(handler: APIGatewayHandler()) {
            // CORS handling
            ExampleMiddleware("CORS", priority: .authentication)
                .order(.authentication)
            
            // API versioning
            if apiVersion == "v1" {
                ExampleMiddleware("APIv1Compatibility", priority: .transformation)
            } else if apiVersion == "v2" {
                ExampleMiddleware("APIv2Validation", priority: .validation)
            }
            
            // Security
            MiddlewareGroup(order: .authentication) {
                ExampleMiddleware("IPWhitelist", priority: .authentication)
                    .when { SecurityConfig.shared.ipWhitelistEnabled }
                
                ExampleMiddleware("APIKeyValidation", priority: .authentication)
                ExampleMiddleware("JWTAuthentication", priority: .authentication)
                    .timeout(2.0)
            }
            
            // Rate limiting with different strategies
            ConditionalMiddleware({ await !isInternalRequest() }) {
                ExampleMiddleware("RateLimiting", priority: .authentication)
                    .retry(maxAttempts: 2, strategy: .fixedDelay(1.0))
                
                ExampleMiddleware("QuotaEnforcement", priority: .rateLimiting)
            }
            
            // Request validation and transformation
            ExampleMiddleware("RequestValidation", priority: .validation)
                .order(.validation)
            
            ExampleMiddleware("RequestTransformation", priority: .transformation)
            
            // Caching layer
            if enableCaching {
                ExampleMiddleware("CacheCheck", priority: .caching)
                    .order(.caching)
            }
            
            // Circuit breaker for backend services
            ExampleMiddleware("CircuitBreaker", priority: .circuitBreaker)
                .retry(maxAttempts: 3, strategy: .exponentialBackoff(base: 0.1, maxDelay: 5.0))
            
            // Debug mode additions
            if debugMode {
                ExampleMiddleware("RequestLogging", priority: .logging)
                ExampleMiddleware("ResponseLogging", priority: .logging)
                ExampleMiddleware("LatencyInjection", priority: .testing)
            }
            
            // Response processing
            ExampleMiddleware("ResponseTransformation", priority: .responseTransformation)
            ExampleMiddleware("Compression", priority: .compression)
                .when { await shouldCompress() }
            
            // Analytics and monitoring in parallel
            ParallelMiddleware(
                ExampleMiddleware("APIMetrics", priority: .metrics),
                ExampleMiddleware("UsageAnalytics", priority: .metrics),
                ExampleMiddleware("AnomalyDetection", priority: .monitoring)
            )
            
            // Cache update
            if enableCaching {
                ExampleMiddleware("CacheUpdate", priority: .responseTransformation)
                    .order(.responseTransformation)
            }
        }
        
        // Example usage
        let request = APIRequest(
            method: .get,
            path: "/api/v2/products",
            headers: ["Authorization": "Bearer token123"],
            body: nil,
            queryParams: ["category": "electronics", "limit": "10"]
        )
        
        let context = CommandContext(metadata: StandardCommandMetadata())
        let response = try await pipeline.execute(request, context: context)
        print("API Response: \(response.statusCode)")
    }
}

// MARK: - Helper Functions

private func isInternalRequest() async -> Bool {
    // Check if request is from internal services
    return false
}

private func shouldCompress() async -> Bool {
    // Determine if response should be compressed
    return true
}

// MARK: - Security Configuration

struct SecurityConfig {
    static let shared = SecurityConfig()
    let ipWhitelistEnabled = false
}

// MARK: - Example Middleware

/// Generic middleware for demonstration purposes
/// In a real application, each middleware would have specific implementations
struct ExampleMiddleware: Middleware {
    let name: String
    let priority: ExecutionPriority
    
    init(_ name: String, priority: ExecutionPriority) {
        self.name = name
        self.priority = priority
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // In a real implementation, each middleware would have specific logic
        // For example:
        // - Authentication would verify tokens
        // - RateLimiting would check request counts
        // - Caching would check/store responses
        // - Logging would record request details
        
        // For demonstration, we just pass through
        return try await next(command, context)
    }
}

/// Special maintenance mode middleware that always throws
struct MaintenanceModeMiddleware: Middleware {
    let priority = ExecutionPriority.authentication
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        throw PipelineErrorType.pipelineNotConfigured
    }
}