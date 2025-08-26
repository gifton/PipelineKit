import XCTest
@testable import PipelineKitSecurity
@testable import PipelineKitCore
import PipelineKit
import PipelineKitTestSupport

final class ValidationTests: XCTestCase {
    // Test command with validation
    private struct CreateUserCommand: Command {
        typealias Result = String
        
        let email: String
        let password: String
        let username: String
        
        func execute() async throws -> String {
            return "User created: \(username)"
        }
        
        func validate() throws {
            try CommandValidator.validateEmail(email)
            try CommandValidator.validateLength(password, field: "password", minLength: 8)
            try CommandValidator.validateNotEmpty(username, field: "username")
            try CommandValidator.validateAlphanumeric(username, field: "username", allowedCharacters: CharacterSet(charactersIn: "_-"))
        }
        
        func sanitize() throws -> CreateUserCommand {
            return self // No sanitization needed for this test
        }
    }
    
    func testValidEmail() throws {
        let validEmails = [
            "test@example.com",
            "user.name@domain.com",
            "user+tag@example.co.uk",
            "123@numbers.com"
        ]
        
        for email in validEmails {
            XCTAssertNoThrow(try CommandValidator.validateEmail(email))
        }
    }
    
    func testInvalidEmail() {
        let invalidEmails = [
            "notanemail",
            "@example.com",
            "user@",
            "user@.com",
            "user space@example.com",
            ""
        ]
        
        for email in invalidEmails {
            XCTAssertThrowsError(try CommandValidator.validateEmail(email)) { error in
                XCTAssertTrue(error is PipelineError)
            }
        }
    }
    
    func testStringLength() throws {
        // Test minimum length
        XCTAssertThrowsError(
            try CommandValidator.validateLength("abc", field: "test", minLength: 5)
        )
        
        // Test maximum length
        XCTAssertThrowsError(
            try CommandValidator.validateLength("abcdefghij", field: "test", maxLength: 5)
        )
        
        // Test valid length
        XCTAssertNoThrow(
            try CommandValidator.validateLength("abcde", field: "test", minLength: 3, maxLength: 10)
        )
    }
    
    func testNotEmpty() throws {
        XCTAssertThrowsError(try CommandValidator.validateNotEmpty("", field: "test"))
        XCTAssertThrowsError(try CommandValidator.validateNotEmpty("   ", field: "test"))
        XCTAssertNoThrow(try CommandValidator.validateNotEmpty("valid", field: "test"))
    }
    
    func testAlphanumeric() throws {
        // Test valid alphanumeric
        XCTAssertNoThrow(
            try CommandValidator.validateAlphanumeric("abc123", field: "test")
        )
        
        // Test with allowed characters
        XCTAssertNoThrow(
            try CommandValidator.validateAlphanumeric(
                "user_name-123",
                field: "test",
                allowedCharacters: CharacterSet(charactersIn: "_-")
            )
        )
        
        // Test invalid characters
        XCTAssertThrowsError(
            try CommandValidator.validateAlphanumeric("user@name", field: "test")
        )
    }
    
    func testValidationMiddleware() async throws {
        struct TestHandler: CommandHandler {
            typealias CommandType = CreateUserCommand
            
            func handle(_ command: CreateUserCommand) async throws -> String {
                // The handler should validate the command itself
                // since ValidationMiddleware uses generic dispatch
                try command.validate()
                return "User created: \(command.username)"
            }
        }
        
        let pipeline = StandardPipeline(handler: TestHandler())
        try await pipeline.addMiddleware(ValidationMiddleware())
        
        // Test valid command
        let validCommand = CreateUserCommand(
            email: "test@example.com",
            password: "securepass123",
            username: "john_doe"
        )
        
        let result = try await pipeline.execute(validCommand)
        XCTAssertEqual(result, "User created: john_doe")
        
        // Test invalid command
        let invalidCommand = CreateUserCommand(
            email: "invalid-email",
            password: "short",
            username: ""
        )
        
        do {
            _ = try await pipeline.execute(invalidCommand)
            XCTFail("Expected validation error")
        } catch {
            XCTAssertTrue(error is PipelineError)
        }
    }
    
    func testValidationErrorMessages() {
        let errors: [(PipelineError, String)] = [
            (.validation(field: nil, reason: .invalidEmail), "Invalid email address"),
            (.validation(field: nil, reason: .weakPassword), "Weak password"),
            (.validation(field: "username", reason: .missingRequired), "Required field missing"),
            (.validation(field: "date", reason: .invalidFormat(expected: "YYYY-MM-DD")), "Invalid format (expected: YYYY-MM-DD)"),
            (.validation(field: "bio", reason: .tooLong(field: "bio", max: 100)), "Field 'bio' exceeds maximum length of 100"),
            (.validation(field: "name", reason: .tooShort(field: "name", min: 2)), "Field 'name' is shorter than minimum length of 2"),
            (.validation(field: "username", reason: .invalidCharacters(field: "username")), "Field 'username' contains invalid characters"),
            (.validation(field: nil, reason: .custom("Custom error")), "Custom error")
        ]
        
        for (error, _) in errors {
            XCTAssertNotNil(error.errorDescription)
        }
    }
}
