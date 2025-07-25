import XCTest
@testable import PipelineKit

// MARK: - Test Support Types for SecurityFailureTests

struct SecurityTestCommand: Command {
    typealias Result = String
    let value: String
}

/// Tests for security failure scenarios and attack resistance
final class SecurityFailureTests: XCTestCase {
    
    // MARK: - Rate Limiting Failures
    
    func testRateLimitExceeded() async throws {
        let rateLimiter = RateLimiter(
            strategy: .slidingWindow(windowSize: 1.0, maxRequests: 2),
            scope: .global
        )
        
        let middleware = RateLimitingMiddleware(limiter: rateLimiter)
        let command = SecurityTestCommand(value: "test")
        let metadata = StandardCommandMetadata()
        
        // First two requests should succeed
        let context = CommandContext(metadata: metadata)
        _ = try await middleware.execute(command, context: context) { _, _ in "success" }
        _ = try await middleware.execute(command, context: context) { _, _ in "success" }
        
        // Third request should fail
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in "fail" }
            XCTFail("Expected rate limit error")
        } catch let error as RateLimitError {
            if case let .limitExceeded(remaining, resetAt) = error {
                XCTAssertEqual(remaining, 0)
                XCTAssertTrue(resetAt.timeIntervalSinceNow > 0)
            } else {
                XCTFail("Expected limitExceeded error")
            }
        }
    }
    
    func testRateLimitBypassAttempt() async throws {
        let rateLimiter = RateLimiter(
            strategy: .tokenBucket(capacity: 1, refillRate: 0.1),
            scope: .perUser
        )
        
        let middleware = RateLimitingMiddleware(limiter: rateLimiter)
        
        // Simulate rapid requests from same user
        let command = SecurityTestCommand(value: "test")
        let metadata = StandardCommandMetadata(userId: "user123")
        let context = CommandContext(metadata: metadata)
        
        // First request consumes the token
        _ = try await middleware.execute(command, context: context) { _, _ in "success" }
        
        // Rapid subsequent requests should fail
        for _ in 0..<5 {
            do {
                _ = try await middleware.execute(command, context: context) { _, _ in "bypass attempt" }
                XCTFail("Rate limit bypass should not succeed")
            } catch is RateLimitError {
                // Expected - rate limit should block
            }
        }
    }
    
    func testCircuitBreakerTrip() async throws {
        let circuitBreaker = CircuitBreaker(
            failureThreshold: 3,
            timeout: 1.0
        )
        
        // Cause enough failures to trip the circuit breaker
        for _ in 0..<3 {
            // Record failures to trip the breaker
            await circuitBreaker.recordFailure()
        }
        
        // Circuit should now be open
        let shouldAllow = await circuitBreaker.shouldAllow()
        XCTAssertFalse(shouldAllow, "Circuit breaker should be open")
        
        // Verify state is open
        let state = await circuitBreaker.getState()
        if case .open = state {
            // Expected - circuit is open
        } else {
            XCTFail("Circuit breaker should be in open state")
        }
    }
    
    // MARK: - Validation Failures
    
    func testValidationFailures() async throws {
        let middleware = ValidationMiddleware()
        
        // Test XSS attempt
        let xssCommand = ValidatableMaliciousCommand(input: "<script>alert('xss')</script>")
        
        do {
            let context = CommandContext(metadata: StandardCommandMetadata())
            _ = try await middleware.execute(xssCommand, context: context) { _, _ in "success" }
            XCTFail("XSS validation should fail")
        } catch let error as ValidationError {
            // Expected validation error
            XCTAssertNotNil(error)
        }
    }
    
    func testSQLInjectionDetection() async throws {
        let middleware = ValidationMiddleware()
        let sqlInjectionCommand = ValidatableMaliciousCommand(input: "'; DROP TABLE users; --")
        
        do {
            let context = CommandContext(metadata: StandardCommandMetadata())
            _ = try await middleware.execute(sqlInjectionCommand, context: context) { _, _ in "success" }
            XCTFail("SQL injection validation should fail")
        } catch let error as ValidationError {
            // Expected validation error for SQL injection
            XCTAssertNotNil(error)
        }
    }
    
    func testExcessiveDataValidation() async throws {
        let middleware = ValidationMiddleware()
        let largeDataCommand = ValidatableMaliciousCommand(input: String(repeating: "A", count: 10000))
        
        do {
            let context = CommandContext(metadata: StandardCommandMetadata())
            _ = try await middleware.execute(largeDataCommand, context: context) { _, _ in "success" }
            XCTFail("Large data validation should fail")
        } catch let error as ValidationError {
            // Expected validation error for excessive data
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Authorization Failures
    
    func testUnauthorizedAccess() async throws {
        let authMiddleware = AuthorizationMiddleware(
            requiredRoles: ["authorized"],
            getUserRoles: { userId in
                // Extract roles based on userId
                if userId == "authorized_user" {
                    return ["authorized"]
                }
                return []
            }
        )
        
        let command = SecurityTestCommand(value: "sensitive_action")
        let unauthorizedMetadata = StandardCommandMetadata(userId: "unauthorized_user")
        let unauthorizedContext = CommandContext(metadata: unauthorizedMetadata)
        
        // Need to set authenticated user in context for authorization middleware
        unauthorizedContext.set("unauthorized_user", for: AuthenticatedUserKey.self)
        
        do {
            _ = try await authMiddleware.execute(command, context: unauthorizedContext) { _, _ in "success" }
            XCTFail("Authorization should deny access")
        } catch AuthorizationError.insufficientPermissions {
            // Expected
        }
    }
    
    func testPrivilegeEscalationAttempt() async throws {
        let authMiddleware = AuthorizationMiddleware(
            requiredRoles: ["admin"],
            getUserRoles: { userId in
                // Only admin users have admin role
                let adminUsers = ["admin1", "admin2"]
                if adminUsers.contains(userId) {
                    return ["admin"]
                }
                return ["user"]
            }
        )
        
        let adminCommand = AdminCommand(action: "delete_all_users")
        let regularUserMetadata = StandardCommandMetadata(userId: "regular_user")
        let regularUserContext = CommandContext(metadata: regularUserMetadata)
        
        // Need to set authenticated user in context for authorization middleware
        regularUserContext.set("regular_user", for: AuthenticatedUserKey.self)
        
        do {
            _ = try await authMiddleware.execute(adminCommand, context: regularUserContext) { _, _ in "success" }
            XCTFail("Privilege escalation should be blocked")
        } catch AuthorizationError.insufficientPermissions {
            // Expected
        }
    }
    
    // MARK: - Encryption Failures
    
    func testEncryptionKeyCorruption() async throws {
        let keyStore1 = InMemoryKeyStore()
        let keyStore2 = InMemoryKeyStore()
        
        let encryptor1 = await CommandEncryptor(keyStore: keyStore1)
        let encryptor2 = await CommandEncryptor(keyStore: keyStore2) // Different key
        
        let command = EncryptableTestCommand(sensitiveData: "secret information")
        
        do {
            let encrypted = try await encryptor1.encrypt(command)
            _ = try await encryptor2.decrypt(encrypted)
            XCTFail("Decryption with wrong key should fail")
        } catch let error as EncryptionError {
            if case .keyNotFound = error {
                // Expected - wrong key
            } else {
                XCTFail("Unexpected encryption error: \(error)")
            }
        }
    }
    
    func testEncryptionWithInvalidData() async throws {
        let keyStore = InMemoryKeyStore()
        let encryptor = await CommandEncryptor(keyStore: keyStore)
        let command = EncryptableTestCommand(sensitiveData: "test")
        
        // Create invalid encrypted command
        let invalidEncrypted = EncryptedCommand(
            originalCommand: command,
            encryptedData: Data("invalid encrypted data".utf8),
            keyIdentifier: "test",
            algorithm: "AES-GCM-256"
        )
        
        do {
            _ = try await encryptor.decrypt(invalidEncrypted)
            XCTFail("Decryption of invalid data should fail")
        } catch {
            // Expected decryption error
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Sanitization Failures
    
    func testSanitizationBypass() async throws {
        let middleware = SanitizationMiddleware()
        
        // Test sophisticated XSS bypass attempts
        let bypassAttempts = [
            "<img src=x onerror=alert('xss')>",
            "<svg onload=alert('xss')>",
            "javascript:alert('xss')",
            "data:text/html,<script>alert('xss')</script>"
        ]
        
        for attempt in bypassAttempts {
            let command = SanitizableMaliciousCommand(input: attempt)
            let context = CommandContext(metadata: StandardCommandMetadata())
            _ = try await middleware.execute(command, context: context) { sanitizedCmd, _ in
                // The middleware should have called sanitized() on the command
                let sanitized = sanitizedCmd.input
                XCTAssertFalse(sanitized.contains("<script"), "Script tag not removed")
                XCTAssertFalse(sanitized.contains("onerror="), "Event handler not removed")
                return "success"
            }
        }
    }
    
    // MARK: - Audit Logging Failures
    
    func testAuditLoggerFileSystemFailure() async throws {
        // Use a read-only directory to simulate file system failure
        let readOnlyURL = URL(fileURLWithPath: "/dev/null/invalid_path")
        
        // AuditLogger doesn't throw on init, but will fail on flush
        let auditLogger = AuditLogger(
            destination: .file(url: readOnlyURL),
            privacyLevel: .full,
            bufferSize: 1
        )
        
        let command = SecurityTestCommand(value: "test")
        let metadata = StandardCommandMetadata()
        
        // This should handle the file system error gracefully
        let entry = AuditEntry(
            commandType: String(describing: type(of: command)),
            userId: metadata.userId ?? "unknown",
            success: true,
            duration: 0.1
        )
        
        // Log will buffer and attempt to flush
        await auditLogger.log(entry)
        
        // Force flush to trigger file system error
        await auditLogger.flush()
        
        // Audit logger should handle the error without throwing
    }
    
    func testAuditLoggerMemoryPressure() async throws {
        let auditLogger = AuditLogger(
            destination: .console,
            privacyLevel: .full,
            bufferSize: 5 // Very small buffer
        )
        
        let metadata = StandardCommandMetadata()
        
        // Generate more entries than buffer size
        for _ in 0..<10 {
            let entry = AuditEntry(
                commandType: "SecurityTestCommand",
                userId: metadata.userId ?? "unknown",
                success: true,
                duration: 0.1
            )
            await auditLogger.log(entry)
        }
        
        // Buffer should handle overflow gracefully (can't query console logs)
        // Just verify no crash occurs
    }
    
    // MARK: - DoS Attack Simulation
    
    func testDoSProtection() async throws {
        let rateLimiter = RateLimiter(
            strategy: .adaptive(baseRate: 10, loadFactor: { await Task { 0.9 }.value }), // High load
            scope: .global
        )
        
        let middleware = RateLimitingMiddleware(limiter: rateLimiter)
        let command = SecurityTestCommand(value: "dos_attempt")
        
        // Simulate coordinated DoS attack
        let attackTasks = (0..<100).map { i in
            Task {
                do {
                    let context = CommandContext(metadata: StandardCommandMetadata())
                    _ = try await middleware.execute(command, context: context) { _, _ in "success" }
                    return true
                } catch {
                    return false
                }
            }
        }
        
        let results = await withTaskGroup(of: Bool.self) { group in
            for task in attackTasks {
                group.addTask { await task.value }
            }
            
            var successCount = 0
            for await result in group {
                if result { successCount += 1 }
            }
            return successCount
        }
        
        // Most requests should be blocked
        XCTAssertLessThan(results, 20, "DoS protection should block most requests")
    }
}

// MARK: - Test Support Types

enum SecurityTestError: Error {
    case simulatedFailure
}

struct SecurityFaultyCommand: Command {
    typealias Result = String
}

struct MaliciousCommand: Command {
    typealias Result = String
    var input: String
}

struct ValidatableMaliciousCommand: Command, ValidatableCommand {
    typealias Result = String
    var input: String
    
    func validate() throws {
        // Check for XSS
        if input.contains("<script>") || input.contains("<svg") || input.contains("javascript:") {
            throw ValidationError.invalidCharacters(field: "input")
        }
        
        // Check for SQL injection patterns
        let sqlPatterns = ["DROP TABLE", "'; DELETE", "UNION SELECT"]
        for pattern in sqlPatterns {
            if input.uppercased().contains(pattern) {
                throw ValidationError.invalidCharacters(field: "input")
            }
        }
        
        // Check for excessive data
        if input.count > 1000 {
            throw ValidationError.valueTooLong(field: "input", maxLength: 1000)
        }
    }
}

struct SanitizableMaliciousCommand: Command, SanitizableCommand {
    typealias Result = String
    var input: String
    
    func sanitized() -> SanitizableMaliciousCommand {
        SanitizableMaliciousCommand(input: CommandSanitizer.sanitizeHTML(input))
    }
}

struct AdminCommand: Command {
    typealias Result = String
    let action: String
}

struct EncryptableTestCommand: Command, EncryptableCommand {
    typealias Result = String
    
    var sensitiveData: String
    
    var sensitiveFields: [String: Any] {
        ["sensitiveData": sensitiveData]
    }
    
    mutating func updateSensitiveFields(_ fields: [String: Any]) {
        if let data = fields["sensitiveData"] as? String {
            self.sensitiveData = data
        }
    }
}
