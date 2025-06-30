import Foundation

/// Example demonstrating how to build a secure pipeline with proper middleware ordering.
public enum SecurityExample {
    
    // MARK: - Main Example
    
    /// Demonstrates building a secure payment processing pipeline
    public static func demonstrateSecurePipeline() async throws {
        // Command and handler setup
        struct CreatePaymentCommand: Command, ValidatableCommand, SanitizableCommand {
            typealias Result = PaymentResult
            
            let cardNumber: String
            let amount: Double
            let currency: String
            let description: String
            
            func validate() throws {
                guard amount > 0 else {
                    throw ValidationError.custom("Amount must be positive")
                }
                guard ["USD", "EUR", "GBP"].contains(currency) else {
                    throw ValidationError.custom("Invalid currency")
                }
                guard cardNumber.count >= 13 && cardNumber.count <= 19 else {
                    throw ValidationError.custom("Invalid card number length")
                }
            }
            
            func sanitized() -> Self {
                CreatePaymentCommand(
                    cardNumber: cardNumber.filter { $0.isNumber },
                    amount: amount,
                    currency: currency.uppercased(),
                    description: CommandSanitizer.sanitizeHTML(description)
                )
            }
        }
        
        struct PaymentResult: Sendable {
            let transactionId: String
            let status: String
        }
        
        struct PaymentHandler: CommandHandler {
            typealias CommandType = CreatePaymentCommand
            
            func handle(_ command: CreatePaymentCommand) async throws -> PaymentResult {
                // Process payment...
                return PaymentResult(
                    transactionId: UUID().uuidString,
                    status: "approved"
                )
            }
        }
        
        // Build secure pipeline with proper ordering
        var builder = SecurePipelineBuilder(handler: PaymentHandler())
        
        // Standard security (validation + sanitization)
        builder.withStandardSecurity()
        
        // Authentication
        builder.withAuthentication(TokenAuthenticationMiddleware())
        
        // Authorization
        builder.withAuthorization(
            AuthorizationMiddleware(
                requiredRoles: Set(["payment:create"]),
                getUserRoles: { userId in
                    // Extract roles from token/session
                    return Set(["payment:create", "user"])
                }
            )
        )
        
        // Rate limiting
        builder.withRateLimiting(
            RateLimitMiddleware(
                limit: 10,
                window: 60 // 10 requests per minute
            )
        )
        
        // Logging
        builder.withLogging(
            AuditLogMiddleware(
                logger: { command, result, context in
                    print("Payment processed: \(await context.commandMetadata.id)")
                }
            )
        )
        
        // Custom fraud detection (between authorization and validation)
        builder.with(
            FraudDetectionMiddleware(),
            order: .authorization
        )
        
        let pipeline = try await builder.build()
        
        // Execute command through secure pipeline
        let command = CreatePaymentCommand(
            cardNumber: "4532 1234 5678 9012",
            amount: 99.99,
            currency: "usd",
            description: "<script>alert('hack')</script>Purchase"
        )
        
        let context = CommandContext(
            metadata: StandardCommandMetadata(userId: "user-123")
        )
        
        let result = try await pipeline.execute(command, context: context)
        
        print("Payment processed: \(result.transactionId)")
    }
    
    // MARK: - Execution Order Demonstration
    
    /// Shows the execution order of security middleware
    public static func demonstrateExecutionOrder() {
        print("Secure Pipeline Execution Order:")
        print("================================")
        
        let securityMiddleware: [(String, ExecutionPriority)] = [
            ("Token Authentication", .authentication),
            ("Session Validation", .session),
            ("Role Authorization", .authorization),
            ("Input Validation", .validation),
            ("Data Sanitization", .sanitization),
            ("Rate Limiting", .rateLimiting),
            ("Audit Logging", .auditLogging),
            ("Metrics Collection", .metrics)
        ]
        
        let sorted = securityMiddleware.sorted { $0.1.rawValue < $1.1.rawValue }
        
        for (index, (name, priority)) in sorted.enumerated() {
            print("\(index + 1). \(name) (priority: \(priority.rawValue))")
        }
    }
    
    // MARK: - Advanced Security Example
    
    /// Demonstrates a multi-layered security approach
    public static func advancedSecurityPipeline() async throws {
        struct SensitiveDataCommand: Command {
            typealias Result = SecureResponse
            let operation: String
            let data: [String: String] // Changed from Any for Sendable conformance
        }
        
        struct SecureResponse: Sendable {
            let encrypted: Data
            let signature: String
        }
        
        struct SecureHandler: CommandHandler {
            func handle(_ command: SensitiveDataCommand) async throws -> SecureResponse {
                // Encrypt response data
                let encrypted = "encrypted_data".data(using: .utf8)!
                return SecureResponse(
                    encrypted: encrypted,
                    signature: "signature_\(UUID().uuidString)"
                )
            }
        }
        
        // Create pipeline with layered security
        let pipeline = try await CreatePipeline(handler: SecureHandler()) {
            // Layer 1: Network Security
            MiddlewareGroup(order: .authentication) {
                IPWhitelistMiddleware(allowedIPs: ["127.0.0.1", "10.0.0.0/8"])
                SSLValidationMiddleware()
                DDoSProtectionMiddleware(requestsPerSecond: 100)
            }
            
            // Layer 2: Authentication & Authorization
            MiddlewareGroup(order: .authentication) {
                MultiFactorAuthMiddleware()
                TokenAuthenticationMiddleware()
                SessionValidationMiddleware()
            }
            
            MiddlewareGroup(order: .authorization) {
                RoleBasedAccessControlMiddleware(requiredRole: "admin")
                ResourcePermissionMiddleware()
            }
            
            // Layer 3: Input Security
            MiddlewareGroup(order: .validation) {
                InputValidationMiddleware()
                SQLInjectionProtectionMiddleware()
                XSSProtectionMiddleware()
            }
            
            // Layer 4: Business Logic Security
            ExampleEncryptionMiddleware()
                .order(.encryption)
            
            DataMaskingMiddleware()
                .order(.transformation)
            
            // Layer 5: Monitoring & Compliance
            MiddlewareGroup(order: .monitoring) {
                ComplianceAuditMiddleware(standard: "PCI-DSS")
                SecurityEventMonitoringMiddleware()
                AnomalyDetectionMiddleware()
            }
        }
        
        let command = SensitiveDataCommand(
            operation: "encrypt",
            data: ["ssn": "123-45-6789", "creditCard": "4111111111111111"]
        )
        
        let context = CommandContext(
            metadata: StandardCommandMetadata(
                userId: "admin-001",
                correlationId: UUID().uuidString
            )
        )
        
        let result = try await pipeline.execute(command, context: context)
        print("Secure operation completed: \(result.signature)")
    }
}

// MARK: - Example Middleware Implementations

struct TokenAuthenticationMiddleware: Middleware {
    let priority = ExecutionPriority.authentication
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Verify JWT token from context
        guard await context.commandMetadata.userId != nil else {
            throw AuthenticationError.invalidToken
        }
        return try await next(command, context)
    }
}

struct RateLimitMiddleware: Middleware {
    let limit: Int
    let window: TimeInterval
    let priority = ExecutionPriority.rateLimiting
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check rate limit...
        return try await next(command, context)
    }
}

struct AuditLogMiddleware: Middleware {
    let logger: @Sendable (Any, Any, CommandContext) async -> Void
    let priority = ExecutionPriority.auditLogging
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let result = try await next(command, context)
        await logger(command, result, context)
        return result
    }
}

struct FraudDetectionMiddleware: Middleware {
    let priority = ExecutionPriority.authorization // Close to authorization
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Perform fraud checks...
        // In a real implementation, you would check command properties
        // For example, check if command conforms to a protocol with amount property
        return try await next(command, context)
    }
}

// Additional security middleware for advanced example
struct IPWhitelistMiddleware: Middleware {
    let allowedIPs: [String]
    let priority = ExecutionPriority.authentication
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check IP whitelist
        return try await next(command, context)
    }
}

struct SSLValidationMiddleware: Middleware {
    let priority = ExecutionPriority.authentication
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Validate SSL certificate
        return try await next(command, context)
    }
}

struct DDoSProtectionMiddleware: Middleware {
    let requestsPerSecond: Int
    let priority = ExecutionPriority.authentication
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check request rate
        return try await next(command, context)
    }
}

struct MultiFactorAuthMiddleware: Middleware {
    let priority = ExecutionPriority.authentication
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Verify MFA token
        return try await next(command, context)
    }
}

struct SessionValidationMiddleware: Middleware {
    let priority = ExecutionPriority.session
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Validate session
        return try await next(command, context)
    }
}

struct RoleBasedAccessControlMiddleware: Middleware {
    let requiredRole: String
    let priority = ExecutionPriority.authorization
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check user roles
        return try await next(command, context)
    }
}

struct ResourcePermissionMiddleware: Middleware {
    let priority = ExecutionPriority.authorization
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check resource permissions
        return try await next(command, context)
    }
}

struct InputValidationMiddleware: Middleware {
    let priority = ExecutionPriority.validation
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Validate input
        return try await next(command, context)
    }
}

struct SQLInjectionProtectionMiddleware: Middleware {
    let priority = ExecutionPriority.validation
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check for SQL injection patterns
        return try await next(command, context)
    }
}

struct XSSProtectionMiddleware: Middleware {
    let priority = ExecutionPriority.validation
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Sanitize XSS attempts
        return try await next(command, context)
    }
}

struct ExampleEncryptionMiddleware: Middleware {
    let priority = ExecutionPriority.encryption
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Encrypt sensitive data
        return try await next(command, context)
    }
}

struct DataMaskingMiddleware: Middleware {
    let priority = ExecutionPriority.transformation
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Mask sensitive data
        return try await next(command, context)
    }
}

struct ComplianceAuditMiddleware: Middleware {
    let standard: String
    let priority = ExecutionPriority.monitoring
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Log for compliance
        return try await next(command, context)
    }
}

struct SecurityEventMonitoringMiddleware: Middleware {
    let priority = ExecutionPriority.monitoring
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Monitor security events
        return try await next(command, context)
    }
}

struct AnomalyDetectionMiddleware: Middleware {
    let priority = ExecutionPriority.monitoring
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Detect anomalies
        return try await next(command, context)
    }
}

// MARK: - Error Types

enum AuthenticationError: Error {
    case invalidToken
    case expired
    case missingCredentials
}

enum SecurityError: Error {
    case suspiciousActivity(String)
    case unauthorized
    case forbidden
}