import XCTest
@testable import PipelineKit

final class ValidationDispatchTests: XCTestCase {
    
    // Test command with custom validation
    struct TestValidationCommand: Command {
        typealias Result = String
        let value: String
        
        func validate() throws {
            print("[TestValidationCommand] validate() called with value: \(value)")
            if value.isEmpty {
                throw PipelineError.validation(field: "value", reason: .missingRequired)
            }
            if value == "invalid" {
                throw PipelineError.validation(field: nil, reason: .custom("Value cannot be 'invalid'"))
            }
        }
        
        func sanitized() throws -> TestValidationCommand {
            return self
        }
    }
    
    func testDirectValidation() throws {
        let command1 = TestValidationCommand(value: "valid")
        let command2 = TestValidationCommand(value: "")
        let command3 = TestValidationCommand(value: "invalid")
        
        // Test valid command
        XCTAssertNoThrow(try command1.validate())
        
        // Test empty value
        XCTAssertThrowsError(try command2.validate()) { error in
            if let pipelineError = error as? PipelineError,
               case .validation(let field, let reason) = pipelineError,
               case .missingRequired = reason {
                XCTAssertEqual(field, "value")
            } else {
                XCTFail("Expected validation error with missingRequired reason")
            }
        }
        
        // Test invalid value
        XCTAssertThrowsError(try command3.validate()) { error in
            if let pipelineError = error as? PipelineError,
               case .validation(_, let reason) = pipelineError,
               case .custom(let message) = reason {
                XCTAssertEqual(message, "Value cannot be 'invalid'")
            } else {
                XCTFail("Expected validation error with custom message")
            }
        }
    }
    
    func testValidationThroughMiddleware() async throws {
        let middleware = ValidationMiddleware()
        let context = CommandContext(metadata: StandardCommandMetadata())
        
        let command1 = TestValidationCommand(value: "valid")
        let command2 = TestValidationCommand(value: "")
        let command3 = TestValidationCommand(value: "invalid")
        
        // Test valid command
        let result1 = try await middleware.execute(command1, context: context) { cmd, _ in
            return "Success: \(cmd.value)"
        }
        XCTAssertEqual(result1, "Success: valid")
        
        // Test empty value command
        do {
            _ = try await middleware.execute(command2, context: context) { cmd, _ in
                return "Should not reach here"
            }
            XCTFail("Middleware should have thrown for empty value")
        } catch {
            if let pipelineError = error as? PipelineError,
               case .validation(let field, let reason) = pipelineError,
               case .missingRequired = reason {
                XCTAssertEqual(field, "value")
            } else {
                XCTFail("Expected validation error with missingRequired reason")
            }
        }
        
        // Test invalid value command
        do {
            _ = try await middleware.execute(command3, context: context) { cmd, _ in
                return "Should not reach here"
            }
            XCTFail("Middleware should have thrown for invalid value")
        } catch {
            if let pipelineError = error as? PipelineError,
               case .validation(_, let reason) = pipelineError,
               case .custom(let message) = reason {
                XCTAssertEqual(message, "Value cannot be 'invalid'")
            } else {
                XCTFail("Expected validation error with custom message")
            }
        }
    }
    
    func testGenericMethodDispatch() throws {
        // Test that validate() is properly dispatched in generic context
        func validateGeneric<T: Command>(_ command: T) throws {
            try command.validate()
        }
        
        let command1 = TestValidationCommand(value: "valid")
        let command2 = TestValidationCommand(value: "")
        
        XCTAssertNoThrow(try validateGeneric(command1))
        XCTAssertThrowsError(try validateGeneric(command2)) { error in
            if let pipelineError = error as? PipelineError,
               case .validation(let field, let reason) = pipelineError,
               case .missingRequired = reason {
                XCTAssertEqual(field, "value")
            } else {
                XCTFail("Expected validation error with missingRequired reason")
            }
        }
    }
    
    func testProtocolWitnessTable() async throws {
        // Test that the protocol witness table correctly dispatches validate()
        let commands: [any Command] = [
            TestValidationCommand(value: "valid"),
            TestValidationCommand(value: ""),
            TestValidationCommand(value: "invalid")
        ]
        
        var results: [Bool] = []
        
        for command in commands {
            do {
                try command.validate()
                results.append(true)
            } catch {
                results.append(false)
            }
        }
        
        XCTAssertEqual(results, [true, false, false])
    }
}