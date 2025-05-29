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
            strategy: .fixedWindow(rate: 2, window: 1.0),
            scope: .global
        )
        
        let middleware = RateLimitingMiddleware(limiter: rateLimiter)
        let command = SecurityTestCommand(value: "test")
        let metadata = DefaultCommandMetadata()
        
        // First two requests should succeed
        _ = try await middleware.execute(command, metadata: metadata) { _, _ in "success" }
        _ = try await middleware.execute(command, metadata: metadata) { _, _ in "success" }
        
        // Third request should fail
        do {
            _ = try await middleware.execute(command, metadata: metadata) { _, _ in "fail" }
            XCTFail("Expected rate limit error")
        } catch let error as RateLimitError {
            XCTAssertEqual(error.remaining, 0)
            XCTAssertTrue(error.retryAfter > 0)
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
        let metadata = DefaultCommandMetadata(userId: "user123")
        
        // First request consumes the token
        _ = try await middleware.execute(command, metadata: metadata) { _, _ in "success" }
        
        // Rapid subsequent requests should fail
        for _ in 0..<5 {
            do {
                _ = try await middleware.execute(command, metadata: metadata) { _, _ in "bypass attempt" }
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
        
        let faultyCommand = FaultyCommand()
        let metadata = DefaultCommandMetadata()
        
        // Cause enough failures to trip the circuit breaker
        for _ in 0..<3 {
            do {
                _ = try await circuitBreaker.execute(faultyCommand, metadata: metadata) { _, _ in
                    throw TestError.simulatedFailure
                }
            } catch TestError.simulatedFailure {
                // Expected failures
            }
        }
        
        // Circuit should now be open
        do {
            _ = try await circuitBreaker.execute(faultyCommand, metadata: metadata) { _, _ in "should not reach" }
            XCTFail("Circuit breaker should be open")
        } catch CircuitBreakerError.circuitOpen {
            // Expected - circuit is open
        }
    }
    
    // MARK: - Validation Failures
    
    func testValidationFailures() async throws {
        let validator = CommandValidator<MaliciousCommand>()
        validator.addRule { command in
            guard !command.input.contains("<script>") else {
                throw ValidationError.invalidInput("XSS attempt detected")
            }
        }
        
        let middleware = ValidationMiddleware(validator: validator)
        
        // Test XSS attempt
        let xssCommand = MaliciousCommand(input: "<script>alert('xss')</script>")
        
        do {
            _ = try await middleware.execute(xssCommand, metadata: DefaultCommandMetadata()) { _, _ in "success" }
            XCTFail("XSS validation should fail")
        } catch let error as ValidationError {
            XCTAssertTrue(error.localizedDescription.contains("XSS attempt detected"))
        }
    }
    
    func testSQLInjectionDetection() async throws {
        let validator = CommandValidator<MaliciousCommand>()
        validator.addRule { command in
            let sqlPatterns = ["DROP TABLE", "'; DELETE", "UNION SELECT"]
            for pattern in sqlPatterns {
                guard !command.input.uppercased().contains(pattern) else {
                    throw ValidationError.invalidInput("SQL injection attempt detected")
                }
            }
        }
        
        let middleware = ValidationMiddleware(validator: validator)
        let sqlInjectionCommand = MaliciousCommand(input: "'; DROP TABLE users; --")
        
        do {
            _ = try await middleware.execute(sqlInjectionCommand, metadata: DefaultCommandMetadata()) { _, _ in "success" }
            XCTFail("SQL injection validation should fail")
        } catch let error as ValidationError {
            XCTAssertTrue(error.localizedDescription.contains("SQL injection attempt detected"))
        }
    }
    
    func testExcessiveDataValidation() async throws {
        let validator = CommandValidator<MaliciousCommand>()
        validator.addRule { command in
            guard command.input.count <= 1000 else {
                throw ValidationError.invalidInput("Input too large")
            }
        }
        
        let middleware = ValidationMiddleware(validator: validator)
        let largeDataCommand = MaliciousCommand(input: String(repeating: "A", count: 10000))
        
        do {
            _ = try await middleware.execute(largeDataCommand, metadata: DefaultCommandMetadata()) { _, _ in "success" }
            XCTFail("Large data validation should fail")
        } catch let error as ValidationError {
            XCTAssertTrue(error.localizedDescription.contains("Input too large"))
        }
    }
    
    // MARK: - Authorization Failures
    
    func testUnauthorizedAccess() async throws {
        let authMiddleware = BasicAuthorizationMiddleware<SecurityTestCommand> { command, metadata in
            guard let userId = metadata.userId, userId == "authorized_user" else {
                throw AuthorizationError.accessDenied("Insufficient privileges")
            }
        }
        
        let command = SecurityTestCommand(value: "sensitive_action")
        let unauthorizedMetadata = DefaultCommandMetadata(userId: "unauthorized_user")
        
        do {
            _ = try await authMiddleware.execute(command, metadata: unauthorizedMetadata) { _, _ in "success" }
            XCTFail("Authorization should deny access")
        } catch let error as AuthorizationError {
            XCTAssertTrue(error.localizedDescription.contains("Insufficient privileges"))
        }
    }
    
    func testPrivilegeEscalationAttempt() async throws {
        let authMiddleware = BasicAuthorizationMiddleware<AdminCommand> { command, metadata in
            guard let userId = metadata.userId else {
                throw AuthorizationError.accessDenied("Authentication required")
            }
            
            // Simulate checking admin role
            let adminUsers = ["admin1", "admin2"]
            guard adminUsers.contains(userId) else {
                throw AuthorizationError.accessDenied("Admin privileges required")
            }
        }
        
        let adminCommand = AdminCommand(action: "delete_all_users")
        let regularUserMetadata = DefaultCommandMetadata(userId: "regular_user")
        
        do {
            _ = try await authMiddleware.execute(adminCommand, metadata: regularUserMetadata) { _, _ in "success" }
            XCTFail("Privilege escalation should be blocked")
        } catch let error as AuthorizationError {
            XCTAssertTrue(error.localizedDescription.contains("Admin privileges required"))
        }
    }
    
    // MARK: - Encryption Failures
    
    func testEncryptionKeyCorruption() async throws {
        let encryptionService = try EncryptionService()
        let command = EncryptableTestCommand(sensitiveData: "secret information")
        
        // Simulate key corruption by using wrong key
        let corruptedService = try EncryptionService() // Different key
        
        do {
            let encrypted = try await encryptionService.encrypt(command)
            _ = try await corruptedService.decrypt(encrypted)
            XCTFail("Decryption with wrong key should fail")
        } catch let error as EncryptionError {
            switch error {
            case .decryptionFailed:
                // Expected - wrong key
                break
            default:
                XCTFail("Unexpected encryption error: \(error)")
            }
        }
    }
    
    func testEncryptionWithInvalidData() async throws {
        let encryptionService = try EncryptionService()
        let invalidEncryptedData = Data("invalid encrypted data".utf8)
        
        do {
            _ = try await encryptionService.decrypt(invalidEncryptedData)
            XCTFail("Decryption of invalid data should fail")
        } catch let error as EncryptionError {
            switch error {
            case .decryptionFailed, .invalidFormat:
                // Expected
                break
            default:
                XCTFail("Unexpected encryption error: \(error)")
            }
        }
    }
    
    // MARK: - Sanitization Failures
    
    func testSanitizationBypass() async throws {
        let sanitizer = CommandSanitizer<MaliciousCommand>()
        sanitizer.addRule { command in
            var sanitized = command
            // Basic HTML tag removal
            sanitized.input = sanitized.input.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return sanitized
        }
        
        let middleware = SanitizationMiddleware()
        
        // Test sophisticated XSS bypass attempts
        let bypassAttempts = [
            "<img src=x onerror=alert('xss')>",
            "<svg onload=alert('xss')>",
            "javascript:alert('xss')",
            "data:text/html,<script>alert('xss')</script>"
        ]
        
        for attempt in bypassAttempts {
            let command = MaliciousCommand(input: attempt)
            let result = try await middleware.execute(command, metadata: DefaultCommandMetadata()) { cmd, _ in
                return cmd.input
            }
            
            // Verify sanitization occurred
            XCTAssertFalse(result.contains("<"), "Sanitization failed for: \(attempt)")
            XCTAssertFalse(result.contains("javascript:"), "Sanitization failed for: \(attempt)")
        }
    }
    
    // MARK: - Audit Logging Failures
    
    func testAuditLoggerFileSystemFailure() async throws {
        // Use a read-only directory to simulate file system failure
        let readOnlyURL = URL(fileURLWithPath: "/dev/null/invalid_path")
        
        do {
            let auditLogger = try AuditLogger(
                destination: .file(url: readOnlyURL),
                privacyLevel: .full
            )
            
            let command = SecurityTestCommand(value: "test")
            let metadata = DefaultCommandMetadata()
            
            // This should handle the file system error gracefully
            let entry = AuditEntry(
                commandType: String(describing: type(of: command)),
                userId: metadata.userId ?? "unknown",
                success: true,
                duration: 0.1
            )
            await auditLogger.log(entry)
            
            // Audit logger should handle the error without throwing
        } catch {
            // If initialization fails, that's also a valid test result
            XCTAssertTrue(error.localizedDescription.contains("invalid_path") || 
                         error.localizedDescription.contains("Permission denied"))
        }
    }
    
    func testAuditLoggerMemoryPressure() async throws {
        let auditLogger = AuditLogger(
            destination: .console,
            privacyLevel: .full,
            bufferSize: 5 // Very small buffer
        )
        
        let command = SecurityTestCommand(value: "test")
        let metadata = DefaultCommandMetadata()
        
        // Generate more entries than buffer size
        for i in 0..<10 {
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
            strategy: .adaptive(baseRate: 10, loadFactor: { 0.9 }), // High load
            scope: .global
        )
        
        let middleware = RateLimitingMiddleware(limiter: rateLimiter)
        let command = SecurityTestCommand(value: "dos_attempt")
        
        // Simulate coordinated DoS attack
        let attackTasks = (0..<100).map { i in
            Task {
                do {
                    _ = try await middleware.execute(command, metadata: DefaultCommandMetadata()) { _, _ in "success" }
                    return true
                } catch is RateLimitError {
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

enum TestError: Error {
    case simulatedFailure
}

struct FaultyCommand: Command {
    typealias Result = String
}

struct MaliciousCommand: Command {
    typealias Result = String
    var input: String
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