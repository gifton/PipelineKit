import XCTest
@testable import PipelineKit

final class CommandValidatorTests: XCTestCase {
    
    // MARK: - Email Validation Tests
    
    func testValidEmailAddresses() throws {
        // Given - Valid email formats
        let validEmails = [
            "user@example.com",
            "user.name@example.com",
            "user+tag@example.co.uk",
            "user_name@example-domain.com",
            "123@example.com",
            "a@b.co"
        ]
        
        // When/Then - Should not throw
        for email in validEmails {
            XCTAssertNoThrow(
                try CommandValidator.validateEmail(email),
                "Email '\(email)' should be valid"
            )
        }
    }
    
    func testInvalidEmailAddresses() {
        // Given - Invalid email formats
        let invalidEmails = [
            "user",                    // No @ symbol
            "@example.com",           // No username
            "user@",                  // No domain
            "user@example",           // No TLD
            "user @example.com",      // Space in username
            "user@exam ple.com",      // Space in domain
            "user@@example.com",      // Double @
            "user@.com",              // Missing domain name
            "user@example..com",      // Double dots
            "",                       // Empty string
            "user@example.c"          // TLD too short
        ]
        
        // When/Then - Should throw
        for email in invalidEmails {
            XCTAssertThrowsError(
                try CommandValidator.validateEmail(email),
                "Email '\(email)' should be invalid"
            ) { error in
                XCTAssertTrue(error is PipelineError)
                if case PipelineError.validation(_, let reason) = error,
                   case .invalidEmail = reason {
                    // Expected
                } else {
                    XCTFail("Expected invalidEmail error for '\(email)'")
                }
            }
        }
    }
    
    // MARK: - Length Validation Tests
    
    func testLengthValidationWithinBounds() throws {
        // Given
        let value = "Hello"
        
        // When/Then - Within bounds
        XCTAssertNoThrow(
            try CommandValidator.validateLength(value, field: "test", minLength: 3, maxLength: 10)
        )
        
        // Exact minimum
        XCTAssertNoThrow(
            try CommandValidator.validateLength(value, field: "test", minLength: 5)
        )
        
        // Exact maximum
        XCTAssertNoThrow(
            try CommandValidator.validateLength(value, field: "test", maxLength: 5)
        )
    }
    
    func testLengthValidationTooShort() {
        // Given
        let value = "Hi"
        
        // When/Then - Too short
        XCTAssertThrowsError(
            try CommandValidator.validateLength(value, field: "username", minLength: 3)
        ) { error in
            if case PipelineError.validation(let field, let reason) = error,
               case .tooShort(let fieldName, let minLength) = reason {
                XCTAssertEqual(field, "username")
                XCTAssertEqual(fieldName, "username")
                XCTAssertEqual(minLength, 3)
            } else {
                XCTFail("Expected valueTooShort error")
            }
        }
    }
    
    func testLengthValidationTooLong() {
        // Given
        let value = "This is a very long string"
        
        // When/Then - Too long
        XCTAssertThrowsError(
            try CommandValidator.validateLength(value, field: "title", maxLength: 10)
        ) { error in
            if case PipelineError.validation(let field, let reason) = error,
               case .tooLong(let fieldName, let maxLength) = reason {
                XCTAssertEqual(field, "title")
                XCTAssertEqual(fieldName, "title")
                XCTAssertEqual(maxLength, 10)
            } else {
                XCTFail("Expected valueTooLong error")
            }
        }
    }
    
    func testLengthValidationNoConstraints() throws {
        // Given
        let value = "Any length string"
        
        // When/Then - No constraints means always valid
        XCTAssertNoThrow(
            try CommandValidator.validateLength(value, field: "test")
        )
    }
    
    // MARK: - Not Empty Validation Tests
    
    func testNotEmptyValidation() throws {
        // Given - Non-empty values
        let validValues = [
            "text",
            " text ",  // With spaces
            "\ttext\n", // With tabs/newlines
            "123",
            "!"
        ]
        
        // When/Then - Should not throw
        for value in validValues {
            XCTAssertNoThrow(
                try CommandValidator.validateNotEmpty(value, field: "test"),
                "Value '\(value)' should not be empty"
            )
        }
    }
    
    func testEmptyValidation() {
        // Given - Empty values
        let emptyValues = [
            "",
            " ",
            "   ",
            "\t",
            "\n",
            "\t\n ",
            "     \t\n"
        ]
        
        // When/Then - Should throw
        for value in emptyValues {
            XCTAssertThrowsError(
                try CommandValidator.validateNotEmpty(value, field: "name")
            ) { error in
                if case PipelineError.validation(let field, let reason) = error,
                   case .missingRequired = reason {
                    XCTAssertEqual(field, "name")
                } else {
                    XCTFail("Expected missingRequiredField error")
                }
            }
        }
    }
    
    // MARK: - Alphanumeric Validation Tests
    
    func testAlphanumericValidation() throws {
        // Given - Alphanumeric values
        let validValues = [
            "abc123",
            "ABC",
            "123",
            "Test123"
        ]
        
        // When/Then - Should not throw
        for value in validValues {
            XCTAssertNoThrow(
                try CommandValidator.validateAlphanumeric(value, field: "test")
            )
        }
    }
    
    func testAlphanumericWithAllowedCharacters() throws {
        // Given
        let allowedChars = CharacterSet(charactersIn: "-_.")
        
        // When/Then - Should allow additional characters
        XCTAssertNoThrow(
            try CommandValidator.validateAlphanumeric("user-name_123.test", field: "test", allowedCharacters: allowedChars)
        )
    }
    
    func testAlphanumericInvalidCharacters() {
        // Given - Values with invalid characters
        let invalidValues = [
            "user@name",     // @ not allowed
            "user name",     // Space not allowed
            "user!",         // ! not allowed
            "user#123",      // # not allowed
            "😀",            // Emoji not allowed
            ""               // Empty string (technically valid but no characters)
        ]
        
        // When/Then - Should throw for invalid characters
        for value in invalidValues {
            if value.isEmpty { continue } // Empty is technically valid
            
            XCTAssertThrowsError(
                try CommandValidator.validateAlphanumeric(value, field: "username")
            ) { error in
                if case PipelineError.validation(let field, let reason) = error,
                   case .invalidCharacters(let fieldName) = reason {
                    XCTAssertEqual(field, "username")
                    XCTAssertEqual(fieldName, "username")
                } else {
                    XCTFail("Expected invalidCharacters error for '\(value)'")
                }
            }
        }
    }
    
    // MARK: - Combined Validation Tests
    
    func testCombinedValidations() throws {
        // Given - A username that must be:
        // - Not empty
        // - 3-20 characters
        // - Alphanumeric with dash/underscore
        
        let username = "valid_user-123"
        
        // When - Apply multiple validations
        XCTAssertNoThrow(try CommandValidator.validateNotEmpty(username, field: "username"))
        XCTAssertNoThrow(try CommandValidator.validateLength(username, field: "username", minLength: 3, maxLength: 20))
        XCTAssertNoThrow(try CommandValidator.validateAlphanumeric(
            username,
            field: "username",
            allowedCharacters: CharacterSet(charactersIn: "-_")
        ))
    }
    
    // MARK: - Edge Cases
    
    func testUnicodeHandling() throws {
        // Given - Unicode strings
        let unicodeEmail = "user@例え.jp"
        let unicodeText = "Hello 世界"
        
        // Email validation should handle unicode domains
        XCTAssertNoThrow(try CommandValidator.validateEmail(unicodeEmail))
        
        // Length validation should count characters correctly
        XCTAssertNoThrow(
            try CommandValidator.validateLength(unicodeText, field: "test", maxLength: 8)
        )
        XCTAssertEqual(unicodeText.count, 8) // Verify our assumption
    }
    
    func testPerformanceOfEmailValidation() {
        // Given
        let emails = (0..<1000).map { "user\($0)@example.com" }
        
        // When/Then - Should complete quickly
        measure {
            for email in emails {
                _ = try? CommandValidator.validateEmail(email)
            }
        }
    }
}