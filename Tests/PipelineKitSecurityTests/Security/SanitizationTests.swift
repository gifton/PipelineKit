import XCTest
@testable import PipelineKitSecurity
@testable import PipelineKitCore
import PipelineKitTestSupport

final class SanitizationTests: XCTestCase {
    // Test command with sanitization
    private struct CreatePostCommand: Command {
        typealias Result = String
        
        let title: String
        let content: String
        let tags: String
        
        func sanitize() throws -> Self {
            CreatePostCommand(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                content: CommandSanitizer.sanitizeHTML(content),
                tags: CommandSanitizer.truncate(tags, maxLength: 50)
            )
        }
    }
    
    func testHTMLSanitization() {
        let tests = [
            (
                input: "<script>alert('xss')</script>Hello",
                expected: "Hello"
            ),
            (
                input: "<div onclick='alert()'>Click me</div>",
                expected: "&lt;div&gt;Click me&lt;/div&gt;"
            ),
            (
                input: "Normal text with <b>bold</b>",
                expected: "Normal text with &lt;b&gt;bold&lt;/b&gt;"
            ),
            (
                input: "<SCRIPT>alert('xss')</SCRIPT>",
                expected: ""
            )
        ]
        
        for test in tests {
            let result = CommandSanitizer.sanitizeHTML(test.input)
            XCTAssertEqual(result, test.expected)
        }
    }
    
    func testHTMLEscaping() {
        let tests = [
            (input: "<div>", expected: "&lt;div&gt;"),
            (input: "a & b", expected: "a &amp; b"),
            (input: "\"quotes\"", expected: "&quot;quotes&quot;"),
            (input: "'apostrophe'", expected: "&#39;apostrophe&#39;")
        ]
        
        for test in tests {
            let result = CommandSanitizer.escapeHTML(test.input)
            XCTAssertEqual(result, test.expected)
        }
    }
    
    func testSQLSanitization() {
        let tests = [
            (input: "O'Brien", expected: "O''Brien"),
            (input: "Line1\nLine2", expected: "Line1\\nLine2"),
            (input: "Return\rhere", expected: "Return\\rhere"),
            (input: "Quote\"Test", expected: "Quote\\\"Test")
        ]
        
        for test in tests {
            let result = CommandSanitizer.sanitizeSQL(test.input)
            XCTAssertEqual(result, test.expected)
        }
    }
    
    func testRemoveNonPrintable() {
        let input = "Hello\0World\u{0001}Test"
        let result = CommandSanitizer.removeNonPrintable(input)
        XCTAssertEqual(result, "HelloWorldTest")
    }
    
    func testTruncate() {
        let input = "This is a very long string that needs to be truncated"
        
        // Test with default suffix
        let result1 = CommandSanitizer.truncate(input, maxLength: 20)
        XCTAssertEqual(result1, "This is a very lo...")
        XCTAssertEqual(result1.count, 20)
        
        // Test with custom suffix
        let result2 = CommandSanitizer.truncate(input, maxLength: 20, suffix: "[...]")
        XCTAssertEqual(result2, "This is a very [...]")
        XCTAssertEqual(result2.count, 20)
        
        // Test when string is shorter than max length
        let shortInput = "Short"
        let result3 = CommandSanitizer.truncate(shortInput, maxLength: 20)
        XCTAssertEqual(result3, "Short")
    }
    
    func testSanitizationMiddleware() async throws {
        let bus = CommandBus()
        try await bus.addMiddleware(SanitizationMiddleware())
        
        struct TestHandler: CommandHandler {
            typealias CommandType = CreatePostCommand
            
            func handle(_ command: CreatePostCommand) async throws -> String {
                return "Post created: \(command.title)"
            }
        }
        
        try await bus.register(CreatePostCommand.self, handler: TestHandler())
        
        // Test command sanitization
        let command = CreatePostCommand(
            title: "  My Post  ",
            content: "<script>alert('xss')</script>Hello <b>World</b>",
            tags: "This is a very long list of tags that should be truncated to fit within the limit"
        )
        
        let result = try await bus.send(command)
        
        // Verify the command was processed
        XCTAssertEqual(result, "Post created: My Post")
        
        // Create a new command to verify sanitization would work
        let sanitizedCommand = try command.sanitize()
        XCTAssertEqual(sanitizedCommand.title, "My Post")
        XCTAssertEqual(sanitizedCommand.content, "Hello &lt;b&gt;World&lt;/b&gt;")
        XCTAssertTrue(sanitizedCommand.tags.count <= 50)
    }
    
    func testSecureCommand() throws {
        struct SecureCreateUserCommand: Command {
            typealias Result = String
            
            let email: String
            let bio: String
            
            func validate() throws {
                try CommandValidator.validateEmail(email)
            }
            
            func sanitize() throws -> Self {
                SecureCreateUserCommand(
                    email: email.lowercased().trimmingCharacters(in: .whitespaces),
                    bio: CommandSanitizer.sanitizeHTML(bio)
                )
            }
        }
        
        let command = SecureCreateUserCommand(
            email: "  TEST@EXAMPLE.COM  ",
            bio: "<script>bad</script>My bio"
        )
        
        // Test validation
        XCTAssertThrowsError(try command.validate()) // Should fail due to spaces
        
        // Sanitize and revalidate
        let sanitizedCommand = try command.sanitize()
        XCTAssertNoThrow(try sanitizedCommand.validate())
        XCTAssertEqual(sanitizedCommand.email, "test@example.com")
        XCTAssertEqual(sanitizedCommand.bio, "My bio")
    }
}
