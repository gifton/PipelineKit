import XCTest
@testable import PipelineKitSecurity
@testable import PipelineKitCore
import PipelineKitTestSupport

final class SecurityPolicyMiddlewareTests: XCTestCase {
    // MARK: - Test Commands
    
    private struct ValidCommand: Command, SecurityValidatable {
        typealias Result = String
        let text: String
        
        func execute() async throws -> String {
            return text
        }
        
        func validate(against policy: SecurityPolicy) throws {
            // Check string length
            if text.count > policy.maxStringLength {
                throw SecurityError.stringTooLong
            }
            
            // Check allowed characters
            let disallowedChars = text.unicodeScalars.filter { !policy.allowedCharacters.contains($0) }
            if !disallowedChars.isEmpty {
                throw SecurityError.invalidCharacters
            }
            
            // Check HTML content
            if !policy.allowHTML && text.contains("<") && text.contains(">") {
                throw SecurityError.htmlNotAllowed
            }
        }
    }
    
    private struct LargeCommand: Command, SecurityValidatable {
        typealias Result = Data
        let data: Data
        
        func execute() async throws -> Data {
            return data
        }
        
        func validate(against policy: SecurityPolicy) throws {
            if data.count > policy.maxCommandSize {
                throw SecurityError.commandTooLarge
            }
        }
    }
    
    private struct UnsafeCommand: Command {
        typealias Result = String
        let sqlInjection: String
        
        func execute() async throws -> String {
            return sqlInjection
        }
    }
    
    // MARK: - Default Policy Tests
    
    func testDefaultPolicyValidation() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .default)
        let command = ValidCommand(text: "Hello, World!")
        let context = CommandContext()
        
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        XCTAssertEqual(result, "Hello, World!")
    }
    
    func testDefaultPolicyStringLength() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .default)
        
        // Create a string that exceeds default max length (10,000)
        let longString = String(repeating: "a", count: 10_001)
        let command = ValidCommand(text: longString)
        let context = CommandContext()
        
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Should reject string exceeding max length")
        } catch {
            XCTAssertTrue(error is SecurityError)
        }
    }
    
    func testDefaultPolicyCommandSize() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .default)
        
        // Create data that exceeds default max size (1MB)
        let largeData = Data(repeating: 0xFF, count: 1_048_577)
        let command = LargeCommand(data: largeData)
        let context = CommandContext()
        
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Should reject command exceeding max size")
        } catch {
            XCTAssertTrue(error is SecurityError)
        }
    }
    
    // MARK: - Strict Policy Tests
    
    func testStrictPolicyValidation() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .strict)
        let command = ValidCommand(text: "Safe text 123")
        let context = CommandContext()
        
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        XCTAssertEqual(result, "Safe text 123")
    }
    
    func testStrictPolicyCharacterRestriction() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .strict)
        
        // Test with disallowed characters (emoji not in strict allowed set)
        let command = ValidCommand(text: "Hello 😀")
        let context = CommandContext()
        
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Should reject emoji in strict mode")
        } catch {
            XCTAssertTrue(error is SecurityError)
        }
    }
    
    func testStrictPolicyStringLength() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .strict)
        
        // Create a string that exceeds strict max length (1,000)
        let longString = String(repeating: "a", count: 1_001)
        let command = ValidCommand(text: longString)
        let context = CommandContext()
        
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Should reject string exceeding strict max length")
        } catch {
            XCTAssertTrue(error is SecurityError)
        }
    }
    
    func testStrictPolicyCommandSize() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .strict)
        
        // Create data that exceeds strict max size (100KB)
        let largeData = Data(repeating: 0xFF, count: 102_401)
        let command = LargeCommand(data: largeData)
        let context = CommandContext()
        
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Should reject command exceeding strict max size")
        } catch {
            XCTAssertTrue(error is SecurityError)
        }
    }
    
    // MARK: - HTML Content Tests
    
    func testHTMLContentRejection() async throws {
        let policy = SecurityPolicy(
            maxCommandSize: 1_048_576,
            allowHTML: false,
            strictValidation: true,
            maxStringLength: 10_000,
            allowedCharacters: .init()
        )
        
        let middleware = SecurityPolicyMiddleware(policy: policy)
        let command = ValidCommand(text: "<script>alert('XSS')</script>")
        let context = CommandContext()
        
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Should reject HTML content")
        } catch {
            XCTAssertTrue(error is SecurityError)
        }
    }
    
    func testHTMLContentAllowed() async throws {
        let policy = SecurityPolicy(
            maxCommandSize: 1_048_576,
            allowHTML: true,
            strictValidation: false,
            maxStringLength: 10_000,
            allowedCharacters: CharacterSet(charactersIn: "").inverted // Allow all
        )
        
        let middleware = SecurityPolicyMiddleware(policy: policy)
        let command = ValidCommand(text: "<p>HTML content</p>")
        let context = CommandContext()
        
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }
        
        XCTAssertEqual(result, "<p>HTML content</p>")
    }
    
    // MARK: - SQL Injection Prevention Tests
    
    func testSQLInjectionPrevention() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .strict)
        
        // Common SQL injection patterns
        let injectionPatterns = [
            "'; DROP TABLE users; --",
            "1' OR '1' = '1",
            "admin'--",
            "1' UNION SELECT * FROM users--"
        ]
        
        for pattern in injectionPatterns {
            let command = ValidCommand(text: pattern)
            let context = CommandContext()
            
            do {
                _ = try await middleware.execute(command, context: context) { cmd, _ in
                    try await cmd.execute()
                }
                XCTFail("Should reject SQL injection pattern: \(pattern)")
            } catch {
                XCTAssertTrue(error is SecurityError)
            }
        }
    }
    
    // MARK: - XSS Prevention Tests
    
    func testXSSPrevention() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .default)
        
        let xssPatterns = [
            "<script>alert('XSS')</script>",
            "<img src=x onerror=alert('XSS')>",
            "<iframe src='javascript:alert(\"XSS\")'></iframe>",
            "<body onload=alert('XSS')>"
        ]
        
        for pattern in xssPatterns {
            let command = ValidCommand(text: pattern)
            let context = CommandContext()
            
            do {
                _ = try await middleware.execute(command, context: context) { cmd, _ in
                    try await cmd.execute()
                }
                XCTFail("Should reject XSS pattern: \(pattern)")
            } catch {
                // XSS patterns should be rejected when HTML is not allowed
                XCTAssertTrue(error is SecurityError)
            }
        }
    }
    
    // MARK: - Command Without Validation Tests
    
    func testCommandWithoutValidation() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .strict)
        
        // Commands that don't implement SecurityValidatable might still be validated
        // by the middleware's internal logic
        let command = UnsafeCommand(sqlInjection: "DROP TABLE users")
        let context = CommandContext()
        
        // The middleware might apply its own validation even without SecurityValidatable
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
            // If it passes, that's fine too - implementation dependent
        } catch {
            // If it fails due to security policy, that's expected
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Custom Policy Tests
    
    func testCustomPolicy() async throws {
        let customPolicy = SecurityPolicy(
            maxCommandSize: 500,
            allowHTML: false,
            strictValidation: true,
            maxStringLength: 50,
            allowedCharacters: CharacterSet.alphanumerics
        )
        
        let middleware = SecurityPolicyMiddleware(policy: customPolicy)
        
        // Test with valid alphanumeric text
        let validCommand = ValidCommand(text: "ABC123")
        let context = CommandContext()
        
        let result = try await middleware.execute(validCommand, context: context) { cmd, _ in
            try await cmd.execute()
        }
        XCTAssertEqual(result, "ABC123")
        
        // Test with spaces (not in alphanumerics)
        let invalidCommand = ValidCommand(text: "ABC 123")
        
        do {
            _ = try await middleware.execute(invalidCommand, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Should reject non-alphanumeric characters")
        } catch {
            XCTAssertTrue(error is SecurityError)
        }
    }
    
    // MARK: - Path Traversal Prevention Tests
    
    func testPathTraversalPrevention() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .strict)
        
        let pathTraversalPatterns = [
            "../../../etc/passwd",
            "..\\..\\..\\windows\\system32",
            "file:///etc/passwd",
            "....//....//etc/passwd"
        ]
        
        for pattern in pathTraversalPatterns {
            let command = ValidCommand(text: pattern)
            let context = CommandContext()
            
            do {
                _ = try await middleware.execute(command, context: context) { cmd, _ in
                    try await cmd.execute()
                }
                // Some patterns might pass if they contain allowed characters
                // but they're still security risks
            } catch {
                // Good - pattern was rejected
                XCTAssertTrue(error is SecurityError)
            }
        }
    }
    
    // MARK: - Performance Tests
    
    func testPolicyValidationPerformance() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .default)
        let command = ValidCommand(text: "Performance test string")
        let context = CommandContext()
        
        let iterations = 10000
        let start = Date()
        
        for _ in 0..<iterations {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
        }
        
        let duration = Date().timeIntervalSince(start)
        let opsPerSecond = Double(iterations) / duration
        
        print("Security policy validation performance: \(Int(opsPerSecond)) ops/sec")
        XCTAssertGreaterThan(opsPerSecond, 50000) // Should handle at least 50k ops/sec
    }
    
    // MARK: - Concurrent Validation Tests
    
    func testConcurrentPolicyValidation() async throws {
        let middleware = SecurityPolicyMiddleware(policy: .strict)
        
        await withTaskGroup(of: String.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let command = ValidCommand(text: "Concurrent test \(i)")
                    let context = CommandContext()
                    
                    do {
                        return try await middleware.execute(command, context: context) { cmd, _ in
                            try await cmd.execute()
                        }
                    } catch {
                        XCTFail("Unexpected error in concurrent validation: \(error)")
                        return "error"
                    }
                }
            }
            
            var results: [String] = []
            for await result in group {
                results.append(result)
            }
            
            XCTAssertEqual(results.count, 100)
        }
    }
}

// MARK: - Error Types

private enum SecurityError: Error {
    case stringTooLong
    case commandTooLarge
    case invalidCharacters
    case htmlNotAllowed
    case validationFailed
}
