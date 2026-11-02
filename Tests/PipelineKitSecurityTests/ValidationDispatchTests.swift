import XCTest
import PipelineKitSecurity
import PipelineKitCore
import PipelineKitTestSupport

final class ValidationDispatchTests: XCTestCase {
    private struct TestValidationCommand: ValidatableCommand {
        typealias Result = String
        let value: String

        func validate() async throws {
            if value.isEmpty {
                throw PipelineError.validation(field: "value", reason: .missingRequired)
            }
            if value == "invalid" {
                throw PipelineError.validation(field: nil, reason: .custom("Value cannot be 'invalid'"))
            }
        }
    }

    func testDirectValidation() async throws {
        try await TestValidationCommand(value: "valid").validate()
        for value in ["", "invalid"] {
            do {
                try await TestValidationCommand(value: value).validate()
                XCTFail("Expected validation failure for \(value)")
            } catch {
                assertValidationError(error, value: value)
            }
        }
    }

    func testValidationThroughMiddleware() async throws {
        let middleware = ValidationMiddleware()
        let context = CommandContext(metadata: TestCommandMetadata())
        let entries = HandlerEntries()

        let result = try await middleware.execute(TestValidationCommand(value: "valid"), context: context) { cmd, _ in
            await entries.record()
            return "Success: \(cmd.value)"
        }
        XCTAssertEqual(result, "Success: valid")
        let successfulEntries = await entries.count
        XCTAssertEqual(successfulEntries, 1)

        await entries.reset()
        for value in ["", "invalid"] {
            do {
                _ = try await middleware.execute(TestValidationCommand(value: value), context: context) { _, _ in
                    await entries.record()
                    return "Reached next handler"
                }
                XCTFail("Expected validation failure for \(value)")
            } catch {
                assertValidationError(error, value: value)
            }
        }
        let rejectedEntries = await entries.count
        XCTAssertEqual(rejectedEntries, 0)
    }

    func testGenericMethodDispatch() async throws {
        func validateGeneric<T: ValidatableCommand>(_ command: T) async throws {
            try await command.validate()
        }

        try await validateGeneric(TestValidationCommand(value: "valid"))
        do {
            try await validateGeneric(TestValidationCommand(value: ""))
            XCTFail("Expected generic validation to reject the empty value")
        } catch {
            assertValidationError(error, value: "")
        }
    }

    func testProtocolWitnessTable() async throws {
        let commands: [any ValidatableCommand] = [
            TestValidationCommand(value: "valid"),
            TestValidationCommand(value: ""),
            TestValidationCommand(value: "invalid")
        ]
        var results: [Bool] = []
        for command in commands {
            do {
                try await command.validate()
                results.append(true)
            } catch {
                results.append(false)
            }
        }
        XCTAssertEqual(results, [true, false, false])
    }

    private func assertValidationError(_ error: any Error, value: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let pipelineError = error as? PipelineError,
              case .validation(let field, let reason) = pipelineError else {
            return XCTFail("Expected validation error, received \(error)", file: file, line: line)
        }
        if value.isEmpty {
            guard case .missingRequired = reason else {
                return XCTFail("Expected missingRequired reason", file: file, line: line)
            }
            XCTAssertEqual(field, "value", file: file, line: line)
        } else {
            guard case .custom(let message) = reason else {
                return XCTFail("Expected custom reason", file: file, line: line)
            }
            XCTAssertEqual(message, "Value cannot be 'invalid'", file: file, line: line)
        }
    }

    private actor HandlerEntries {
        private(set) var count = 0
        func record() { count += 1 }
        func reset() { count = 0 }
    }
}
