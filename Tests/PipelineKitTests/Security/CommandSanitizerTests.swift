import XCTest
@testable import PipelineKit

final class CommandSanitizerTests: XCTestCase {
    
    // MARK: - HTML Sanitization Tests
    
    func testSanitizeHTMLRemovesScriptTags() {
        // Given - HTML with script tags
        let inputs = [
            "<script>alert('XSS')</script>Hello",
            "Hello<script type='text/javascript'>malicious();</script>World",
            "<SCRIPT>alert('XSS')</SCRIPT>", // Case insensitive
            "<script src='evil.js'></script>",
            "Before<script>\nmalicious\ncode\n</script>After"
        ]
        
        // When/Then - Script tags should be removed
        for input in inputs {
            let sanitized = CommandSanitizer.sanitizeHTML(input)
            XCTAssertFalse(sanitized.lowercased().contains("<script"))
            XCTAssertFalse(sanitized.lowercased().contains("</script>"))
            XCTAssertFalse(sanitized.contains("alert"))
            XCTAssertFalse(sanitized.contains("malicious"))
        }
    }
    
    func testSanitizeHTMLRemovesEventHandlers() {
        // Given - HTML with event handlers
        let inputs = [
            "<div onclick='alert(\"XSS\")'>Click me</div>",
            "<img src='x' onerror='alert(1)'>",
            "<body onload='malicious()'>",
            "<a href='#' onmouseover='steal()'>Link</a>",
            "<input onchange='hack()' value='test'>"
        ]
        
        // When/Then - Event handlers should be removed
        for input in inputs {
            let sanitized = CommandSanitizer.sanitizeHTML(input)
            XCTAssertFalse(sanitized.contains("onclick"))
            XCTAssertFalse(sanitized.contains("onerror"))
            XCTAssertFalse(sanitized.contains("onload"))
            XCTAssertFalse(sanitized.contains("onmouseover"))
            XCTAssertFalse(sanitized.contains("onchange"))
        }
    }
    
    func testSanitizeHTMLEscapesEntities() {
        // Given
        let input = "<p>Hello & \"World\" with 'quotes' and <tags></p>"
        
        // When
        let sanitized = CommandSanitizer.sanitizeHTML(input)
        
        // Then - Should escape HTML entities
        XCTAssertTrue(sanitized.contains("&lt;p&gt;"))
        XCTAssertTrue(sanitized.contains("&lt;/p&gt;"))
        XCTAssertTrue(sanitized.contains("&amp;"))
        XCTAssertTrue(sanitized.contains("&quot;"))
        XCTAssertTrue(sanitized.contains("&#39;"))
        XCTAssertFalse(sanitized.contains("<p>"))
        XCTAssertFalse(sanitized.contains("</p>"))
    }
    
    func testSanitizeHTMLComplexCase() {
        // Given - Complex malicious HTML
        let input = """
        <div>
            Normal text
            <script>alert('XSS')</script>
            <img src='x' onerror='alert(1)'>
            <a href='javascript:void(0)' onclick='steal()'>Click</a>
            More text & "quotes"
        </div>
        """
        
        // When
        let sanitized = CommandSanitizer.sanitizeHTML(input)
        
        // Then
        XCTAssertTrue(sanitized.contains("Normal text"))
        XCTAssertTrue(sanitized.contains("More text"))
        XCTAssertFalse(sanitized.contains("<script"))
        XCTAssertFalse(sanitized.contains("onclick="))
        XCTAssertFalse(sanitized.contains("onerror="))
        XCTAssertTrue(sanitized.contains("&amp;"))
        XCTAssertTrue(sanitized.contains("&quot;"))
    }
    
    // MARK: - HTML Escape Tests
    
    func testEscapeHTML() {
        // Given
        let input = "Test & < > \" ' characters"
        
        // When
        let escaped = CommandSanitizer.escapeHTML(input)
        
        // Then
        XCTAssertEqual(escaped, "Test &amp; &lt; &gt; &quot; &#39; characters")
    }
    
    func testEscapeHTMLEmpty() {
        // Given/When/Then
        XCTAssertEqual(CommandSanitizer.escapeHTML(""), "")
    }
    
    func testEscapeHTMLNoSpecialCharacters() {
        // Given
        let input = "Plain text with no special characters"
        
        // When/Then
        XCTAssertEqual(CommandSanitizer.escapeHTML(input), input)
    }
    
    // MARK: - SQL Sanitization Tests
    
    func testSanitizeSQLBasic() {
        // Given
        let inputs = [
            ("O'Brien", "O''Brien"),
            ("Line1\nLine2", "Line1\\nLine2"),
            ("Tab\there", "Tab\\rhere"),
            ("Quote\"Test", "Quote\\\"Test"),
            ("Back\\slash", "Back\\\\slash"),
            ("Null\0Char", "Null\\0Char")
        ]
        
        // When/Then
        for (input, expected) in inputs {
            let sanitized = CommandSanitizer.sanitizeSQL(input)
            XCTAssertEqual(sanitized, expected)
        }
    }
    
    func testSanitizeSQLInjectionAttempts() {
        // Given - Common SQL injection patterns
        let injections = [
            "'; DROP TABLE users; --",
            "' OR '1'='1",
            "admin'--",
            "' UNION SELECT * FROM passwords --"
        ]
        
        // When/Then - Should escape quotes
        for injection in injections {
            let sanitized = CommandSanitizer.sanitizeSQL(injection)
            // The single quotes should be doubled
            let singleQuoteCount = sanitized.filter { $0 == "'" }.count
            let originalQuoteCount = injection.filter { $0 == "'" }.count
            XCTAssertEqual(singleQuoteCount, originalQuoteCount * 2)
        }
    }
    
    // MARK: - Non-Printable Character Tests
    
    func testRemoveNonPrintable() {
        // Given
        let input = "Hello\u{0000}World\u{0001}Test\u{001F}!"
        
        // When
        let cleaned = CommandSanitizer.removeNonPrintable(input)
        
        // Then
        XCTAssertEqual(cleaned, "HelloWorldTest!")
    }
    
    func testRemoveNonPrintableKeepsValidCharacters() {
        // Given - All types of valid characters
        let input = """
        ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789
        !@#$%^&*()_+-=[]{}|;':",./<>?
        Hello World\tTab\nNewline
        """
        
        // When
        let cleaned = CommandSanitizer.removeNonPrintable(input)
        
        // Then - Should keep all printable characters
        XCTAssertTrue(cleaned.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertTrue(cleaned.contains("abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(cleaned.contains("0123456789"))
        XCTAssertTrue(cleaned.contains("!@#$%^&*()"))
        XCTAssertTrue(cleaned.contains("Hello World"))
    }
    
    func testRemoveNonPrintableEmoji() {
        // Given - Text with emoji (which are in the symbols character set)
        let input = "Hello 😀 World 🌍!"
        
        // When
        let cleaned = CommandSanitizer.removeNonPrintable(input)
        
        // Then - Emoji should be kept (they're in symbols)
        XCTAssertTrue(cleaned.contains("😀"))
        XCTAssertTrue(cleaned.contains("🌍"))
    }
    
    // MARK: - Truncation Tests
    
    func testTruncateShortString() {
        // Given
        let input = "Short"
        
        // When/Then - Should not truncate
        XCTAssertEqual(CommandSanitizer.truncate(input, maxLength: 10), "Short")
    }
    
    func testTruncateLongString() {
        // Given
        let input = "This is a very long string that needs truncation"
        
        // When
        let truncated = CommandSanitizer.truncate(input, maxLength: 20)
        
        // Then
        XCTAssertEqual(truncated, "This is a very lo...")
        XCTAssertEqual(truncated.count, 20)
    }
    
    func testTruncateCustomSuffix() {
        // Given
        let input = "Truncate this text please"
        
        // When
        let truncated = CommandSanitizer.truncate(input, maxLength: 15, suffix: "[...]")
        
        // Then
        XCTAssertEqual(truncated, "Truncate t[...]")
        XCTAssertEqual(truncated.count, 15)
    }
    
    func testTruncateExactLength() {
        // Given
        let input = "Exactly10!"
        
        // When/Then - Should not truncate when exact length
        XCTAssertEqual(CommandSanitizer.truncate(input, maxLength: 10), "Exactly10!")
    }
    
    func testTruncateEmptyString() {
        // Given/When/Then
        XCTAssertEqual(CommandSanitizer.truncate("", maxLength: 10), "")
    }
    
    func testTruncateUnicode() {
        // Given - String with unicode characters
        let input = "Hello 世界 from Swift"
        
        // When
        let truncated = CommandSanitizer.truncate(input, maxLength: 10)
        
        // Then - Should handle unicode correctly
        XCTAssertEqual(truncated, "Hello 世...")
        XCTAssertEqual(truncated.count, 10)
    }
    
    // MARK: - Performance Tests
    
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
    
    // MARK: - Integration Tests
    
    func testFullSanitizationPipeline() {
        // Given - User input that needs full sanitization
        let userInput = """
        <script>alert('XSS')</script>
        Hello, my name is O'Brien!
        <div onclick='steal()'>Click me</div>
        Some text with \u{0000} non-printable \u{0001} characters.
        This is a very long description that should be truncated to a reasonable length for display purposes.
        """
        
        // When - Apply full sanitization pipeline
        var sanitized = userInput
        sanitized = CommandSanitizer.sanitizeHTML(sanitized)
        sanitized = CommandSanitizer.removeNonPrintable(sanitized)
        sanitized = CommandSanitizer.truncate(sanitized, maxLength: 100)
        
        // Then
        XCTAssertFalse(sanitized.contains("<script"))
        XCTAssertFalse(sanitized.contains("onclick"))
        XCTAssertFalse(sanitized.contains("\u{0000}"))
        XCTAssertLessThanOrEqual(sanitized.count, 100)
        XCTAssertTrue(sanitized.contains("Hello"))
        XCTAssertTrue(sanitized.contains("O&#39;Brien")) // Escaped apostrophe
    }
}