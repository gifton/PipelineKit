import XCTest
@testable import PipelineKit

final class AuthorizationMiddlewareTests: XCTestCase {
    
    func testSuccessfulAuthorization() async throws {
        // Given
        let middleware = AuthorizationMiddleware(
            requiredRoles: ["user", "admin"],
            getUserRoles: { userId in
                // Mock role extraction
                if userId == "admin-user" {
                    return ["user", "admin"]
                }
                return ["user"]
            }
        )
        
        let command = AuthzTestCommand(value: "test")
        let context = CommandContext()
        
        // Set authenticated user
        await context.set("admin-user", for: AuthenticatedUserKey.self)
        
        let handlerExecutedBox = Box(value: false)
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            handlerExecutedBox.value = true
            return cmd.value
        }
        
        // Then
        XCTAssertTrue(handlerExecutedBox.value)
        XCTAssertEqual(result, "test")
    }
    
    func testAuthorizationFailureInsufficientRoles() async throws {
        // Given
        let middleware = AuthorizationMiddleware(
            requiredRoles: ["admin"],
            getUserRoles: { userId in
                return ["user"] // User doesn't have admin role
            }
        )
        
        let command = AuthzTestCommand(value: "test")
        let context = CommandContext()
        await context.set("regular-user", for: AuthenticatedUserKey.self)
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Handler should not be called without required roles")
                return ""
            }
            XCTFail("Should throw authorization error")
        } catch let error as AuthorizationError {
            // Expected error
            XCTAssertEqual(error.localizedDescription, AuthorizationError.insufficientPermissions.localizedDescription)
        }
    }
    
    func testAuthorizationFailureMissingUser() async throws {
        // Given
        let middleware = AuthorizationMiddleware(
            requiredRoles: ["user"],
            getUserRoles: { _ in ["user"] }
        )
        
        let command = AuthzTestCommand(value: "test")
        let context = CommandContext()
        // No authenticated user set
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Handler should not be called without authenticated user")
                return ""
            }
            XCTFail("Should throw authorization error")
        } catch let error as AuthorizationError {
            // Expected error
            XCTAssertEqual(error.localizedDescription, AuthorizationError.notAuthenticated.localizedDescription)
        }
    }
    
    func testAuthorizationWithMultipleRoles() async throws {
        // Given
        let middleware = AuthorizationMiddleware(
            requiredRoles: ["read", "write"],
            getUserRoles: { userId in
                switch userId {
                case "reader": return ["read"]
                case "writer": return ["write"]
                case "editor": return ["read", "write"]
                default: return []
                }
            }
        )
        
        let command = AuthzTestCommand(value: "test")
        
        // Test editor (has both roles)
        let editorContext = CommandContext()
        await editorContext.set("editor", for: AuthenticatedUserKey.self)
        
        let editorResult = try await middleware.execute(command, context: editorContext) { cmd, _ in
            cmd.value
        }
        XCTAssertEqual(editorResult, "test")
        
        // Test reader (missing write role)
        let readerContext = CommandContext()
        await readerContext.set("reader", for: AuthenticatedUserKey.self)
        
        do {
            _ = try await middleware.execute(command, context: readerContext) { _, _ in
                XCTFail("Should not execute for reader")
                return ""
            }
            XCTFail("Should throw authorization error")
        } catch {
            XCTAssertTrue(error is AuthorizationError)
        }
    }
    
    func testCustomRoleExtractor() async throws {
        // Given
        let extractorCalledBox = Box(value: false)
        let middleware = AuthorizationMiddleware(
            requiredRoles: ["premium"],
            getUserRoles: { userId in
                extractorCalledBox.value = true
                
                // Simulate database lookup
                if userId.hasSuffix("-premium") {
                    return ["user", "premium"]
                }
                return ["user"]
            }
        )
        
        let command = AuthzTestCommand(value: "test")
        let context = CommandContext()
        await context.set("user123-premium", for: AuthenticatedUserKey.self)
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            cmd.value
        }
        
        // Then
        XCTAssertTrue(extractorCalledBox.value)
        XCTAssertEqual(result, "test")
    }
    
    func testAuthorizationPriority() {
        let middleware = AuthorizationMiddleware(
            requiredRoles: ["user"],
            getUserRoles: { _ in [] }
        )
        XCTAssertEqual(middleware.priority, .authorization)
    }
    
    func testConcurrentAuthorization() async throws {
        // Given
        let middleware = AuthorizationMiddleware(
            requiredRoles: ["user"],
            getUserRoles: { userId in
                // Simulate async role lookup
                try await Task.sleep(nanoseconds: 5_000_000) // 5ms
                return userId.hasPrefix("valid-") ? ["user"] : []
            }
        )
        
        // When - Execute multiple authorizations concurrently
        let tasks = (0..<10).map { i in
            Task {
                let command = AuthzTestCommand(value: "test-\(i)")
                let context = CommandContext()
                let userId = i % 2 == 0 ? "valid-user-\(i)" : "invalid-user-\(i)"
                await context.set(userId, for: AuthenticatedUserKey.self)
                
                do {
                    return try await middleware.execute(command, context: context) { cmd, _ in
                        cmd.value
                    }
                } catch {
                    return "error"
                }
            }
        }
        
        // Then - Half should succeed, half should fail
        var successCount = 0
        for (i, task) in tasks.enumerated() {
            let result = await task.value
            if i % 2 == 0 {
                XCTAssertEqual(result, "test-\(i)")
                successCount += 1
            } else {
                XCTAssertEqual(result, "error")
            }
        }
        XCTAssertEqual(successCount, 5)
    }
    
    func testEmptyRequiredRoles() async throws {
        // Given - No roles required (public endpoint)
        let middleware = AuthorizationMiddleware(
            requiredRoles: [],
            getUserRoles: { _ in [] }
        )
        
        let command = AuthzTestCommand(value: "test")
        let context = CommandContext()
        // No user needed for public endpoints
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            cmd.value
        }
        
        // Then
        XCTAssertEqual(result, "test")
    }
}

// Test support types
private struct AuthzTestCommand: Command {
    typealias Result = String
    let value: String
    
    func execute() async throws -> String {
        return value
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(value: T) {
        self.value = value
    }
}