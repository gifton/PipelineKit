import XCTest
@testable import PipelineKitCore

final class ContextCopyableTests: XCTestCase {
    
    // Example reference type that implements ContextCopyable
    final class UserSession: ContextCopyable, @unchecked Sendable {
        var id: String
        var permissions: Set<String>
        var loginTime: Date
        
        init(id: String, permissions: Set<String> = [], loginTime: Date = Date()) {
            self.id = id
            self.permissions = permissions
            self.loginTime = loginTime
        }
        
        func contextCopy() -> UserSession {
            return UserSession(
                id: id,
                permissions: permissions,  // Set is value type, gets copied
                loginTime: loginTime
            )
        }
    }
    
    // Define test context keys
    struct TestContextKeys {
        static let session = ContextKey<UserSession>("test.session")
        static let counter = ContextKey<Int>("test.counter")
        static let name = ContextKey<String>("test.name")
    }
    
    func testShallowForkSharesReferences() {
        let context = CommandContext()
        let session = UserSession(id: "user123", permissions: ["read", "write"])
        context[TestContextKeys.session] = session
        context[TestContextKeys.counter] = 42
        
        let forked = context.fork()
        
        // Reference types are shared
        XCTAssertTrue(forked[TestContextKeys.session] === session, "Shallow fork should share reference types")
        
        // Value types are copied
        XCTAssertEqual(forked[TestContextKeys.counter], 42)
        
        // Modifying the shared reference affects both contexts
        session.permissions.insert("admin")
        XCTAssertTrue(context[TestContextKeys.session]?.permissions.contains("admin") ?? false)
        XCTAssertTrue(forked[TestContextKeys.session]?.permissions.contains("admin") ?? false)
    }
    
    func testManualDeepCopy() {
        let context = CommandContext()
        let session = UserSession(id: "user123", permissions: ["read", "write"])
        context[TestContextKeys.session] = session
        
        // Manual deep copy
        let forked = context.fork()
        if let originalSession = context[TestContextKeys.session] as? ContextCopyable {
            forked[TestContextKeys.session] = originalSession.contextCopy() as? UserSession
        }
        
        // Different instances
        XCTAssertTrue(forked[TestContextKeys.session] !== session, "Deep copy should create new instance")
        
        // Modifying the copy doesn't affect original
        forked[TestContextKeys.session]?.permissions.insert("admin")
        XCTAssertFalse(session.permissions.contains("admin"))
        XCTAssertTrue(forked[TestContextKeys.session]?.permissions.contains("admin") ?? false)
    }
    
    func testDeepForkConvenienceMethod() {
        let context = CommandContext()
        let session = UserSession(id: "user123", permissions: ["read"])
        context[TestContextKeys.session] = session
        context[TestContextKeys.name] = "John"
        
        // Use convenience method
        let forked = context.deepFork(copying: [TestContextKeys.session])
        
        // Session is deep copied
        XCTAssertTrue(forked[TestContextKeys.session] !== session, "Deep fork should create new instance")
        
        // String is value type, always copied
        XCTAssertEqual(forked[TestContextKeys.name], "John")
        
        // Verify isolation
        forked[TestContextKeys.session]?.permissions.insert("write")
        XCTAssertEqual(session.permissions, ["read"])
        XCTAssertEqual(forked[TestContextKeys.session]?.permissions, ["read", "write"])
    }
    
    func testMixedCopyBehavior() {
        // Demonstrates that users can mix shallow and deep copying
        let context = CommandContext()
        
        let session1 = UserSession(id: "user1", permissions: ["read"])
        let session2 = UserSession(id: "user2", permissions: ["write"])
        
        context[TestContextKeys.session] = session1
        context[ContextKey<UserSession>("session2")] = session2
        
        let forked = context.fork()
        
        // Deep copy only session1
        if let s1 = context[TestContextKeys.session] as? ContextCopyable {
            forked[TestContextKeys.session] = s1.contextCopy() as? UserSession
        }
        // session2 remains shared
        
        XCTAssertTrue(forked[TestContextKeys.session] !== session1, "session1 should be deep copied")
        XCTAssertTrue(forked[ContextKey<UserSession>("session2")] === session2, "session2 should be shared")
    }
}