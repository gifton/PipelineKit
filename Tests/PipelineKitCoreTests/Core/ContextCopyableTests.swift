import XCTest
@testable import PipelineKitCore

final class ContextCopyableTests: XCTestCase {
    // Example reference type that implements ContextCopyable
    private final class UserSession: ContextCopyable, @unchecked Sendable {
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
    private enum TestContextKeys {
        static let session = ContextKey<UserSession>("test.session")
        static let counter = ContextKey<Int>("test.counter")
        static let name = ContextKey<String>("test.name")
    }
    
    func testShallowForkSharesReferences() async {
        let context = CommandContext()
        let session = UserSession(id: "user123", permissions: ["read", "write"])
        context[TestContextKeys.session] = session
        context[TestContextKeys.counter] = 42
        
        let forked = context.fork()
        
        // Reference types are shared
        let forkedSession: UserSession? = forked[TestContextKeys.session]
        XCTAssertTrue(forkedSession === session, "Shallow fork should share reference types")

        // Value types are copied
        let forkedCounter: Int? = forked[TestContextKeys.counter]
        XCTAssertEqual(forkedCounter, 42)

        // Modifying the shared reference affects both contexts
        session.permissions.insert("admin")
        let contextSession: UserSession? = context[TestContextKeys.session]
        XCTAssertTrue(contextSession?.permissions.contains("admin") ?? false)
        let finalForkedSession: UserSession? = forked[TestContextKeys.session]
        XCTAssertTrue(finalForkedSession?.permissions.contains("admin") ?? false)
    }
    
    func testManualDeepCopy() async {
        let context = CommandContext()
        let session = UserSession(id: "user123", permissions: ["read", "write"])
        context[TestContextKeys.session] = session
        
        // Manual deep copy
        let forked = context.fork()
        let sessionCopy: UserSession? = context[TestContextKeys.session]
        forked[TestContextKeys.session] = sessionCopy?.contextCopy() as? UserSession
        
        // Different instances
        let forkedSession: UserSession? = forked[TestContextKeys.session]
        XCTAssertTrue(forkedSession !== session, "Deep copy should create new instance")
        
        // Modifying the copy doesn't affect original
        if let forkedSession: UserSession = forked[TestContextKeys.session] {
            forkedSession.permissions.insert("admin")
        }
        XCTAssertFalse(session.permissions.contains("admin"))
        let finalForkedSession: UserSession? = forked[TestContextKeys.session]
        XCTAssertTrue(finalForkedSession?.permissions.contains("admin") ?? false)
    }
    
    func testDeepForkConvenienceMethod() async {
        let context = CommandContext()
        let session = UserSession(id: "user123", permissions: ["read"])
        context[TestContextKeys.session] = session
        context[TestContextKeys.name] = "John"
        
        // Use convenience method
        let forked = await context.deepFork(copying: [TestContextKeys.session])

        // Session is deep copied
        let forkedSession: UserSession? = forked[TestContextKeys.session]
        XCTAssertTrue(forkedSession !== session, "Deep fork should create new instance")
        
        // String is value type, always copied
        let forkedName: String? = forked[TestContextKeys.name]
        XCTAssertEqual(forkedName, "John")
        
        // Verify isolation
        if let forkedSession: UserSession = forked[TestContextKeys.session] {
            forkedSession.permissions.insert("write")
        }
        XCTAssertEqual(session.permissions, ["read"])
        let finalForkedSession: UserSession? = forked[TestContextKeys.session]
        XCTAssertEqual(finalForkedSession?.permissions, ["read", "write"])
    }
    
    func testMixedCopyBehavior() async {
        // Demonstrates that users can mix shallow and deep copying
        let context = CommandContext()

        let session1 = UserSession(id: "user1", permissions: ["read"])
        let session2 = UserSession(id: "user2", permissions: ["write"])

        context[TestContextKeys.session] = session1
        context[ContextKey<UserSession>("session2")] = session2
        
        let forked = context.fork()

        // Deep copy only session1
        let session1Copy: UserSession? = context[TestContextKeys.session]
        forked[TestContextKeys.session] = session1Copy?.contextCopy() as? UserSession
        // session2 remains shared

        let forkedSession1: UserSession? = forked[TestContextKeys.session]
        let forkedSession2: UserSession? = forked[ContextKey<UserSession>("session2")]
        XCTAssertTrue(forkedSession1 !== session1, "session1 should be deep copied")
        XCTAssertTrue(forkedSession2 === session2, "session2 should be shared")
    }
}
