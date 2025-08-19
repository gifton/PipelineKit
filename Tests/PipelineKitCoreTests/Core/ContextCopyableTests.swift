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
    
    func testShallowForkSharesReferences() async {
        let context = CommandContext()
        let session = UserSession(id: "user123", permissions: ["read", "write"])
        await context.set(TestContextKeys.session, value: session)
        await context.set(TestContextKeys.counter, value: 42)
        
        let forked = await context.fork()
        
        // Reference types are shared
        let forkedSession = await forked.get(TestContextKeys.session)
        XCTAssertTrue(forkedSession === session, "Shallow fork should share reference types")
        
        // Value types are copied
        let forkedCounter: Int? = await forked.get(TestContextKeys.counter)
        XCTAssertEqual(forkedCounter, 42)
        
        // Modifying the shared reference affects both contexts
        session.permissions.insert("admin")
        let contextSession = await context.get(TestContextKeys.session)
        XCTAssertTrue(contextSession?.permissions.contains("admin") ?? false)
        let finalForkedSession = await forked.get(TestContextKeys.session)
        XCTAssertTrue(finalForkedSession?.permissions.contains("admin") ?? false)
    }
    
    func testManualDeepCopy() async {
        let context = CommandContext()
        let session = UserSession(id: "user123", permissions: ["read", "write"])
        await context.set(TestContextKeys.session, value: session)
        
        // Manual deep copy
        let forked = await context.fork()
        if let originalSession = await context.get(TestContextKeys.session) as? ContextCopyable {
            await forked.set(TestContextKeys.session, value: originalSession.contextCopy() as? UserSession)
        }
        
        // Different instances
        let forkedSession = await forked.get(TestContextKeys.session)
        XCTAssertTrue(forkedSession !== session, "Deep copy should create new instance")
        
        // Modifying the copy doesn't affect original
        if let forkedSession = await forked.get(TestContextKeys.session) {
            forkedSession.permissions.insert("admin")
        }
        XCTAssertFalse(session.permissions.contains("admin"))
        let finalForkedSession = await forked.get(TestContextKeys.session)
        XCTAssertTrue(finalForkedSession?.permissions.contains("admin") ?? false)
    }
    
    func testDeepForkConvenienceMethod() async {
        let context = CommandContext()
        let session = UserSession(id: "user123", permissions: ["read"])
        await context.set(TestContextKeys.session, value: session)
        await context.set(TestContextKeys.name, value: "John")
        
        // Use convenience method
        let forked = await context.deepFork(copying: [TestContextKeys.session])
        
        // Session is deep copied
        let forkedSession = await forked.get(TestContextKeys.session)
        XCTAssertTrue(forkedSession !== session, "Deep fork should create new instance")
        
        // String is value type, always copied
        let forkedName: String? = await forked.get(TestContextKeys.name)
        XCTAssertEqual(forkedName, "John")
        
        // Verify isolation
        if let forkedSession = await forked.get(TestContextKeys.session) {
            forkedSession.permissions.insert("write")
        }
        XCTAssertEqual(session.permissions, ["read"])
        let finalForkedSession = await forked.get(TestContextKeys.session)
        XCTAssertEqual(finalForkedSession?.permissions, ["read", "write"])
    }
    
    func testMixedCopyBehavior() async {
        // Demonstrates that users can mix shallow and deep copying
        let context = CommandContext()
        
        let session1 = UserSession(id: "user1", permissions: ["read"])
        let session2 = UserSession(id: "user2", permissions: ["write"])
        
        await context.set(TestContextKeys.session, value: session1)
        await context.set(ContextKey<UserSession>("session2"), value: session2)
        
        let forked = await context.fork()
        
        // Deep copy only session1
        if let s1 = await context.get(TestContextKeys.session) as? ContextCopyable {
            await forked.set(TestContextKeys.session, value: s1.contextCopy() as? UserSession)
        }
        // session2 remains shared
        
        let forkedSession1 = await forked.get(TestContextKeys.session)
        let forkedSession2 = await forked.get(ContextKey<UserSession>("session2"))
        XCTAssertTrue(forkedSession1 !== session1, "session1 should be deep copied")
        XCTAssertTrue(forkedSession2 === session2, "session2 should be shared")
    }
}