import XCTest
@testable import PipelineKit

final class RegexValidationBenchmark: XCTestCase {
    // MARK: - Email Validation Benchmarks
    
    func testEmailValidationPerformance() throws {
        let validEmails = [
            "test@example.com",
            "user.name@domain.co.uk",
            "first+last@company.org",
            "123456@numbers.net",
            "test_underscore@test.com"
        ]
        
        let invalidEmails = [
            "notanemail",
            "@missing.com",
            "test@",
            "test@.com",
            "test..double@test.com"
        ]
        
        measure {
            for _ in 0..<1000 {
                for email in validEmails {
                    _ = try? CommandValidator.validateEmail(email)
                }
                for email in invalidEmails {
                    _ = try? CommandValidator.validateEmail(email)
                }
            }
        }
    }
    
    func testEmailValidationWithPrecompiledRegex() throws {
        // Create a pre-compiled regex version for comparison
        let emailRegex = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        let precompiledRegex = try NSRegularExpression(pattern: emailRegex, options: .caseInsensitive)
        
        let validEmails = [
            "test@example.com",
            "user.name@domain.co.uk",
            "first+last@company.org",
            "123456@numbers.net",
            "test_underscore@test.com"
        ]
        
        let invalidEmails = [
            "notanemail",
            "@missing.com",
            "test@",
            "test@.com",
            "test..double@test.com"
        ]
        
        measure {
            for _ in 0..<1000 {
                for email in validEmails {
                    let range = NSRange(location: 0, length: email.utf16.count)
                    _ = precompiledRegex.firstMatch(in: email, options: [], range: range) != nil
                }
                for email in invalidEmails {
                    let range = NSRange(location: 0, length: email.utf16.count)
                    _ = precompiledRegex.firstMatch(in: email, options: [], range: range) != nil
                }
            }
        }
    }
    
    // MARK: - HTML Detection Benchmarks
    
    func testHTMLDetectionPerformance() throws {
        let htmlStrings = [
            "<div>Hello World</div>",
            "Text with <b>bold</b> tags",
            "<script>alert('xss')</script>",
            "Multiple <p>paragraph</p> <span>tags</span>",
            "<img src='test.jpg' />"
        ]
        
        let nonHtmlStrings = [
            "Plain text without HTML",
            "Math expression: 5 < 10 and 10 > 5",
            "Email: test@example.com",
            "URL: https://example.com",
            "Code: if (x < y) { return true; }"
        ]
        
        // Create a mock security policy instance
        let policy = SecurityPolicy.default
        let middleware = SecurityPolicyMiddleware(policy: policy)
        
        measure {
            for _ in 0..<1000 {
                for html in htmlStrings {
                    _ = containsHTMLUsingReflection(middleware, html)
                }
                for text in nonHtmlStrings {
                    _ = containsHTMLUsingReflection(middleware, text)
                }
            }
        }
    }
    
    func testHTMLDetectionWithPrecompiledRegex() throws {
        let htmlPattern = "<[^>]+>"
        let precompiledRegex = try NSRegularExpression(pattern: htmlPattern, options: .caseInsensitive)
        
        let htmlStrings = [
            "<div>Hello World</div>",
            "Text with <b>bold</b> tags",
            "<script>alert('xss')</script>",
            "Multiple <p>paragraph</p> <span>tags</span>",
            "<img src='test.jpg' />"
        ]
        
        let nonHtmlStrings = [
            "Plain text without HTML",
            "Math expression: 5 < 10 and 10 > 5",
            "Email: test@example.com",
            "URL: https://example.com",
            "Code: if (x < y) { return true; }"
        ]
        
        measure {
            for _ in 0..<1000 {
                for html in htmlStrings {
                    let range = NSRange(location: 0, length: html.utf16.count)
                    _ = precompiledRegex.firstMatch(in: html, options: [], range: range) != nil
                }
                for text in nonHtmlStrings {
                    let range = NSRange(location: 0, length: text.utf16.count)
                    _ = precompiledRegex.firstMatch(in: text, options: [], range: range) != nil
                }
            }
        }
    }
    
    // MARK: - Alternative Validation Methods
    
    func testEmailValidationWithSimpleCheck() throws {
        // Test a simple non-regex email validation
        let validEmails = [
            "test@example.com",
            "user.name@domain.co.uk",
            "first+last@company.org",
            "123456@numbers.net",
            "test_underscore@test.com"
        ]
        
        let invalidEmails = [
            "notanemail",
            "@missing.com",
            "test@",
            "test@.com",
            "test..double@test.com"
        ]
        
        measure {
            for _ in 0..<1000 {
                for email in validEmails {
                    _ = isValidEmailSimple(email)
                }
                for email in invalidEmails {
                    _ = isValidEmailSimple(email)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func containsHTMLUsingReflection(_ middleware: SecurityPolicyMiddleware, _ string: String) -> Bool {
        // Access the private containsHTML method using reflection
        let mirror = Mirror(reflecting: middleware)
        
        // Since we can't directly call private methods, we'll reproduce the logic
        let htmlPattern = "<[^>]+>"
        let regex = try? NSRegularExpression(pattern: htmlPattern, options: .caseInsensitive)
        let range = NSRange(location: 0, length: string.utf16.count)
        return regex?.firstMatch(in: string, options: [], range: range) != nil
    }
    
    private func isValidEmailSimple(_ email: String) -> Bool {
        // Simple email validation without regex
        let atIndex = email.firstIndex(of: "@")
        guard let at = atIndex else { return false }
        
        let localPart = email[..<at]
        let domainPart = email[email.index(after: at)...]
        
        // Basic checks
        guard !localPart.isEmpty && !domainPart.isEmpty else { return false }
        
        // Check for dot in domain
        guard domainPart.contains(".") else { return false }
        
        // Check last dot position
        if let lastDot = domainPart.lastIndex(of: ".") {
            let tld = domainPart[domainPart.index(after: lastDot)...]
            guard tld.count >= 2 else { return false }
        }
        
        return true
    }
}
