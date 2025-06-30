import XCTest
@testable import PipelineKit

final class ValidationTests: XCTestCase {
    
    // Test command with validation
    struct CreateUserCommand: Command, ValidatableCommand {
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
                XCTAssertTrue(error is ValidationError)
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
        let bus = CommandBus()
        try await bus.addMiddleware(ValidationMiddleware())
        
        struct TestHandler: CommandHandler {
            typealias CommandType = CreateUserCommand
            
            func handle(_ command: CreateUserCommand) async throws -> String {
                return "User created: \(command.username)"
            }
        }
        
        try await bus.register(CreateUserCommand.self, handler: TestHandler())
        
        // Test valid command
        let validCommand = CreateUserCommand(
            email: "test@example.com",
            password: "securepass123",
            username: "john_doe"
        )
        
        let result = try await bus.send(validCommand)
        XCTAssertEqual(result, "User created: john_doe")
        
        // Test invalid command
        let invalidCommand = CreateUserCommand(
            email: "invalid-email",
            password: "short",
            username: ""
        )
        
        do {
            _ = try await bus.send(invalidCommand)
            XCTFail("Expected validation error")
        } catch {
            XCTAssertTrue(error is ValidationError)
        }
    }
    
    func testValidationErrorMessages() {
        let errors: [(ValidationError, String)] = [
            (.invalidEmail, "Invalid email address format"),
            (.weakPassword, "Password does not meet security requirements"),
            (.missingRequiredField("username"), "Required field 'username' is missing"),
            (.invalidFormat(field: "date", expectedFormat: "YYYY-MM-DD"), "Field 'date' does not match expected format: YYYY-MM-DD"),
            (.valueTooLong(field: "bio", maxLength: 100), "Field 'bio' exceeds maximum length of 100"),
            (.valueTooShort(field: "name", minLength: 2), "Field 'name' is shorter than minimum length of 2"),
            (.invalidCharacters(field: "username"), "Field 'username' contains invalid characters"),
            (.custom("Custom error"), "Custom error")
        ]
        
        for (error, expectedMessage) in errors {
            XCTAssertEqual(error.errorDescription, expectedMessage)
        }
    }
}