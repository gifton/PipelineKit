import XCTest
@testable import PipelineKitSecurity
@testable import PipelineKitCore
import PipelineKitTestSupport

final class OptimizedValidatorsTests: XCTestCase {
    // MARK: - Email Validation Tests
    
    func testValidEmails() {
        let validEmails = [
            "test@example.com",
            "user.name@domain.co.uk",
            "first+last@company.org",
            "123456@numbers.net",
            "test_underscore@test.com",
            "a@b.co",
            "test.multiple.dots@example.com",
            "user+tag@example.com"
        ]
        
        for email in validEmails {
            XCTAssertTrue(
                OptimizedValidators.validateEmail(email),
                "Email '\(email)' should be valid"
            )
        }
    }
    
    func testInvalidEmails() {
        let invalidEmails = [
            "",
            "notanemail",
            "@missing.com",
            "test@",
            "test@.com",
            "test..double@test.com",
            "test@@double.com",
            "test@domain",
            "test.com",
            "test @domain.com",
            "test@domain .com",
            "@",
            "test@",
            "@domain.com"
        ]
        
        for email in invalidEmails {
            XCTAssertFalse(
                OptimizedValidators.validateEmail(email),
                "Email '\(email)' should be invalid"
            )
        }
    }
    
    func testEmailValidationEdgeCases() {
        // Very long email
        let longLocal = String(repeating: "a", count: 64)
        let longEmail = "\(longLocal)@example.com"
        XCTAssertTrue(OptimizedValidators.validateEmail(longEmail))
        
        // Domain with hyphens
        XCTAssertTrue(OptimizedValidators.validateEmail("test@my-domain.com"))
        XCTAssertTrue(OptimizedValidators.validateEmail("test@sub.my-domain.com"))
        
        // Multiple subdomains
        XCTAssertTrue(OptimizedValidators.validateEmail("test@mail.company.co.uk"))
    }
    
    // MARK: - HTML Detection Tests
    
    func testHTMLDetection() {
        let htmlStrings = [
            "<div>Hello World</div>",
            "Text with <b>bold</b> tags",
            "<script>alert('xss')</script>",
            "Multiple <p>paragraph</p> <span>tags</span>",
            "<img src='test.jpg' />",
            "<br>",
            "<hr/>",
            "<input type='text'>",
            "<!-- comment -->",
            "<tag with='attributes' and=\"quotes\">"
        ]
        
        for html in htmlStrings {
            XCTAssertTrue(
                OptimizedValidators.containsHTML(html),
                "String '\(html)' should be detected as containing HTML"
            )
        }
    }
    
    func testNonHTMLStrings() {
        let nonHtmlStrings = [
            "Plain text without HTML",
            "Math expression: 5 < 10 and 10 > 5",
            "Email: test@example.com",
            "URL: https://example.com",
            "Code: if (x < y) { return true; }",
            "Less than < and greater than >",
            "Template syntax {{variable}}",
            "Markdown **bold** and *italic*",
            "Path: /usr/local/bin",
            "Emoticons: <3 and >:("
        ]
        
        for text in nonHtmlStrings {
            XCTAssertFalse(
                OptimizedValidators.containsHTML(text),
                "String '\(text)' should not be detected as containing HTML"
            )
        }
    }
    
    func testHTMLDetectionEdgeCases() {
        // Self-closing tags
        XCTAssertTrue(OptimizedValidators.containsHTML("<br/>"))
        XCTAssertTrue(OptimizedValidators.containsHTML("<img src='test' />"))
        
        // Tags with attributes
        XCTAssertTrue(OptimizedValidators.containsHTML("<div class='test'>"))
        XCTAssertTrue(OptimizedValidators.containsHTML("<a href='#'>"))
        
        // Case insensitive
        XCTAssertTrue(OptimizedValidators.containsHTML("<DIV>"))
        XCTAssertTrue(OptimizedValidators.containsHTML("<Script>"))
        
        // Empty string
        XCTAssertFalse(OptimizedValidators.containsHTML(""))
    }
    
    // MARK: - Simple Email Validation Tests
    
    func testSimpleEmailValidation() {
        // Test that simple validation catches basic issues
        let testCases: [(email: String, expected: Bool)] = [
            ("test@example.com", true),
            ("user.name@domain.co.uk", true),
            ("test@sub.domain.com", true),
            ("a@b.co", true),
            ("test..double@example.com", false),
            (".startdot@example.com", false),
            ("enddot.@example.com", false),
            ("@example.com", false),
            ("test@", false),
            ("test", false),
            ("test@domain", false),
            ("test@.com", false),
            ("test@domain..com", false),
            ("test@-domain.com", false),
            ("test@domain-.com", false),
            ("test@domain.c", false), // TLD too short
            ("", false)
        ]
        
        for (email, expected) in testCases {
            XCTAssertEqual(
                OptimizedValidators.validateEmailSimple(email),
                expected,
                "Simple validation for '\(email)' should return \(expected)"
            )
        }
    }
    
    // MARK: - Thread Safety Tests
    
    func testThreadSafetyOfValidators() async {
        // Test that validators are thread-safe
        let iterations = 1000
        let emails = ["test@example.com", "invalid.email", "user@domain.org"]
        let htmlStrings = ["<div>test</div>", "plain text", "<script>alert()</script>"]
        
        await withTaskGroup(of: Void.self) { group in
            // Email validation from multiple threads
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<iterations {
                        if let email = emails.randomElement() {
                            _ = OptimizedValidators.validateEmail(email)
                        }
                    }
                }
            }
            
            // HTML detection from multiple threads
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<iterations {
                        if let html = htmlStrings.randomElement() {
                            _ = OptimizedValidators.containsHTML(html)
                        }
                    }
                }
            }
        }
        
        // If we get here without crashes, validators are thread-safe
        XCTAssertTrue(true)
    }
    
    // MARK: - Performance Comparison Test
    
    func testPerformanceComparison() {
        let emails = Array(repeating: [
            "test@example.com",
            "user.name@domain.co.uk",
            "invalid.email",
            "another@test.org"
        ], count: 250).flatMap { $0 }
        
        // Measure regex validation
        let regexTime = measureTime {
            for email in emails {
                _ = OptimizedValidators.validateEmail(email)
            }
        }
        
        // Measure simple validation
        let simpleTime = measureTime {
            for email in emails {
                _ = OptimizedValidators.validateEmailSimple(email)
            }
        }
        
        print("Regex validation: \(regexTime)s")
        print("Simple validation: \(simpleTime)s")
        
        // Simple validation should generally be faster
        // But both should be very fast
        // Using more generous thresholds for CI environments where performance can vary
        // 50ms is still very fast for 1000 validations (0.05ms per validation)
        XCTAssertLessThan(regexTime, 0.05, "Regex validation should complete within 50ms")
        XCTAssertLessThan(simpleTime, 0.05, "Simple validation should complete within 50ms")
        
        // Optional: Log relative performance (simple should generally be faster)
        if simpleTime < regexTime {
            print("✓ Simple validation is \(String(format: "%.1f", regexTime / simpleTime))x faster than regex")
        }
    }
    
    private func measureTime(_ block: () -> Void) -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return CFAbsoluteTimeGetCurrent() - start
    }
}
