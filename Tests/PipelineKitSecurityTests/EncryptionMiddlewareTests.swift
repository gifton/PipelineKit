import XCTest
import PipelineKitCore
import PipelineKitSecurity
import CryptoKit

// Example encryptable command for testing
struct CreateUserCommand: Command, EncryptableCommand {
    typealias Result = UserCreatedResult
    
    let username: String
    let password: String
    let email: String
    
    // EncryptableCommand conformance
    var sensitiveData: [String: any Encodable] {
        return [
            "password": password,
            "email": email
        ]
    }
    
    func withEncryptedData(_ encryptedData: [String: EncryptedData]) -> CreateUserCommand {
        // In a real implementation, store encrypted data
        // For testing, just return self
        return self
    }
}

struct UserCreatedResult: Sendable {
    let userId: String
    let success: Bool
}

final class EncryptionMiddlewareTests: XCTestCase {
    
    func testEncryptionMiddleware() async throws {
        // Create encryption service
        let encryptionService = StandardEncryptionService()
        
        // Create middleware
        let middleware = EncryptionMiddleware(
            encryptionService: encryptionService,
            sensitiveFields: ["password", "email"]
        )
        
        // Create test command
        let command = CreateUserCommand(
            username: "testuser",
            password: "secretpassword123",
            email: "test@example.com"
        )
        
        // Create context
        let context = CommandContext()
        
        // Test handler
        let handler: @Sendable (CreateUserCommand, CommandContext) async throws -> UserCreatedResult = { cmd, ctx in
            // Verify encryption was applied
            XCTAssertEqual(ctx.metadata["encryption.applied"] as? Bool, true)
            XCTAssertNotNil(ctx.metadata["encryption.timestamp"])
            
            return UserCreatedResult(userId: "123", success: true)
        }
        
        // Execute through middleware
        let result = try await middleware.execute(command, context: context, next: handler)
        
        // Verify result
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.userId, "123")
    }
    
    func testEncryptionWithAuditLogging() async throws {
        // Create mock audit logger
        let auditLogger = DefaultAuditLogger(
            destination: .console,
            privacyLevel: .masked
        )
        
        // Create encryption service
        let encryptionService = StandardEncryptionService()
        
        // Create middleware
        let middleware = EncryptionMiddleware(
            encryptionService: encryptionService,
            sensitiveFields: ["password"]
        )
        
        // Create test command
        let command = CreateUserCommand(
            username: "testuser",
            password: "secretpassword123",
            email: "test@example.com"
        )
        
        // Create context with audit logger
        let context = CommandContext()
        context.metadata["auditLogger"] = auditLogger as any AuditLogger
        
        // Test handler
        let handler: @Sendable (CreateUserCommand, CommandContext) async throws -> UserCreatedResult = { _, _ in
            UserCreatedResult(userId: "456", success: true)
        }
        
        // Execute through middleware
        let result = try await middleware.execute(command, context: context, next: handler)
        
        // Verify result
        XCTAssertTrue(result.success)
    }
}