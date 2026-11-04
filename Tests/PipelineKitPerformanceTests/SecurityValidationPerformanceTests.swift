import XCTest
import PipelineKitSecurity

final class SecurityValidationPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if targetEnvironment(simulator)
        throw XCTSkip("Performance measurements are not meaningful on emulated simulator runners")
        #endif
    }

    func testSanitizeHTMLPerformance() {
        // Given
        let html = "<script>alert('XSS')</script><div onclick='hack()'>Test</div>" + String(repeating: "Normal text ", count: 100)

        // When/Then
        measure {
            for _ in 0..<100 {
                _ = CommandSanitizer.sanitizeHTML(html)
            }
        }
    }

    func testRemoveNonPrintablePerformance() {
        // Given
        let input = String(repeating: "Test\u{0000}String\u{0001}With\u{001F}NonPrintable ", count: 100)

        // When/Then
        measure {
            for _ in 0..<100 {
                _ = CommandSanitizer.removeNonPrintable(input)
            }
        }
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
