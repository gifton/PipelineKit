import XCTest
@testable import PipelineKit

final class QuickRegexPerformanceTest: XCTestCase {
    
    func testEmailValidationPerformanceImprovement() throws {
        let emails = [
            "test@example.com",
            "user.name@domain.co.uk", 
            "invalid.email",
            "another@test.org",
            "@invalid.com"
        ]
        
        let iterations = 10000
        
        // Test old approach (NSPredicate)
        let oldApproachTime = measureTime {
            for _ in 0..<iterations {
                for email in emails {
                    let emailRegex = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
                    let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
                    _ = emailPredicate.evaluate(with: email)
                }
            }
        }
        
        // Test new approach (pre-compiled regex)
        let newApproachTime = measureTime {
            for _ in 0..<iterations {
                for email in emails {
                    _ = OptimizedValidators.validateEmail(email)
                }
            }
        }
        
        let improvement = ((oldApproachTime - newApproachTime) / oldApproachTime) * 100
        print("Email validation improvement: \(String(format: "%.1f", improvement))%")
        print("Old approach: \(String(format: "%.3f", oldApproachTime))s")
        print("New approach: \(String(format: "%.3f", newApproachTime))s")
        
        XCTAssertLessThan(newApproachTime, oldApproachTime)
    }
    
    func testHTMLDetectionPerformanceImprovement() throws {
        let strings = [
            "<div>Hello</div>",
            "Plain text",
            "<script>alert('test')</script>",
            "No HTML here",
            "Some <b>bold</b> text"
        ]
        
        let iterations = 10000
        
        // Test old approach (creating regex each time)
        let oldApproachTime = measureTime {
            for _ in 0..<iterations {
                for string in strings {
                    let htmlPattern = "<[^>]+>"
                    let regex = try? NSRegularExpression(pattern: htmlPattern, options: .caseInsensitive)
                    let range = NSRange(location: 0, length: string.utf16.count)
                    _ = regex?.firstMatch(in: string, options: [], range: range) != nil
                }
            }
        }
        
        // Test new approach (pre-compiled regex)
        let newApproachTime = measureTime {
            for _ in 0..<iterations {
                for string in strings {
                    _ = OptimizedValidators.containsHTML(string)
                }
            }
        }
        
        let improvement = ((oldApproachTime - newApproachTime) / oldApproachTime) * 100
        print("\nHTML detection improvement: \(String(format: "%.1f", improvement))%")
        print("Old approach: \(String(format: "%.3f", oldApproachTime))s")
        print("New approach: \(String(format: "%.3f", newApproachTime))s")
        
        XCTAssertLessThan(newApproachTime, oldApproachTime)
    }
    
    private func measureTime(_ block: () -> Void) -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return CFAbsoluteTimeGetCurrent() - start
    }
}