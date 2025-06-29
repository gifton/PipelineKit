import Foundation

/// Example demonstrating how to build a secure pipeline with proper middleware ordering.
func demonstrateSecurePipeline() async throws {
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
            requiredRoles: ["payment:create"],
            roleExtractor: { metadata in
                // Extract roles from token/session
                return ["payment:create", "user"]
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
            logger: { command, result, metadata in
                print("Payment processed: \(metadata.id)")
            }
        )
    )
    
    // Custom fraud detection (between authorization and validation)
    builder.with(
        SecureFraudDetectionMiddleware(),
        order: ExecutionPriority.custom // or use ExecutionPriority.between(.authorization, and: .validation)
    )
    
    let pipeline = try await builder.build()
    
    // Execute command through secure pipeline
    let command = CreatePaymentCommand(
        cardNumber: "4532 1234 5678 9012",
        amount: 99.99,
        currency: "usd",
        description: "<script>alert('hack')</script>Purchase"
    )
    
    let result = try await pipeline.execute(
        command,
        metadata: StandardCommandMetadata(userId: "user-123")
    )
    
    print("Payment processed: \(result.transactionId)")
}

/// Example showing the execution order
func demonstrateExecutionOrder() {
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

// MARK: - Example Middleware Implementations

struct TokenAuthenticationMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Verify JWT token from metadata
        guard metadata.userId != nil else {
            throw AuthenticationError.invalidToken
        }
        return try await next(command, metadata)
    }
}

struct RateLimitMiddleware: Middleware {
    let limit: Int
    let window: TimeInterval
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Check rate limit...
        return try await next(command, metadata)
    }
}

struct AuditLogMiddleware: Middleware {
    let logger: @Sendable (Any, Any, CommandMetadata) async -> Void
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        let result = try await next(command, metadata)
        await logger(command, result, metadata)
        return result
    }
}

struct SecureFraudDetectionMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Perform fraud checks...
        return try await next(command, metadata)
    }
}

enum AuthenticationError: Error {
    case invalidToken
}