import XCTest
@testable import PipelineKitSecurity
@testable import PipelineKitCore
import PipelineKitTestSupport

final class AuthorizationMiddlewareTests: XCTestCase {
    func testSuccessfulAuthorization() async throws {
        // Given
        let middleware = AuthorizationMiddleware(
            requiredRoles: Set(["user", "admin"]),
            getUserRoles: { userId in
                // Mock role extraction
                if userId == "admin-user" {
                    return Set(["user", "admin"])
                }
                return Set(["user"])
            }
        )
        
        let command = AuthzTestCommand(value: "test")
        let context = CommandContext()
        
        // Set authenticated user
        context.setMetadata("authUserId", value: "admin-user")
        
        let handlerExecutedBox = Box(value: false)
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
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
            requiredRoles: Set(["admin"]),
            getUserRoles: { _ in
                return Set(["user"]) // User doesn't have admin role
            }
        )
        
        let command = AuthzTestCommand(value: "test")
        let context = CommandContext()
        context.setMetadata("authUserId", value: "regular-user")
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Handler should not be called without required roles")
                return ""
            }
            XCTFail("Should throw authorization error")
        } catch let error as PipelineError {
            // Expected error
            if case .authorization(let reason) = error,
               case .insufficientPermissions = reason {
                // Expected
            } else {
                XCTFail("Expected insufficientPermissions error")
            }
        }
    }
    
    func testAuthorizationFailureMissingUser() async throws {
        // Given
        let middleware = AuthorizationMiddleware(
            requiredRoles: Set(["user"]),
            getUserRoles: { _ in Set(["user"]) }
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
        } catch let error as PipelineError {
            // Expected error
            if case .authorization(let reason) = error,
               case .invalidCredentials = reason {
                // Expected - no authenticated user
            } else {
                XCTFail("Expected authorization error")
            }
        }
    }
    
    func testAuthorizationWithMultipleRoles() async throws {
        // Given
        let middleware = AuthorizationMiddleware(
            requiredRoles: Set(["read", "write"]),
            getUserRoles: { userId in
                switch userId {
                case "reader": return Set(["read"])
                case "writer": return Set(["write"])
                case "editor": return Set(["read", "write"])
                default: return Set()
                }
            }
        )
        
        let command = AuthzTestCommand(value: "test")
        
        // Test editor (has both roles)
        let editorContext = CommandContext()
        await editorContext.setMetadata("authUserId", value: "editor")
        
        let editorResult = try await middleware.execute(command, context: editorContext) { cmd, _ in
            cmd.value
        }
        XCTAssertEqual(editorResult, "test")
        
        // Test reader (missing write role)
        let readerContext = CommandContext()
        await readerContext.setMetadata("authUserId", value: "reader")
        
        do {
            _ = try await middleware.execute(command, context: readerContext) { _, _ in
                XCTFail("Should not execute for reader")
                return ""
            }
            XCTFail("Should throw authorization error")
        } catch {
            XCTAssertTrue(error is PipelineError)
        }
    }
    
    func testCustomRoleExtractor() async throws {
        // Given
        let extractorCalledBox = Box(value: false)
        let middleware = AuthorizationMiddleware(
            requiredRoles: Set(["premium"]),
            getUserRoles: { userId in
                extractorCalledBox.value = true
                
                // Simulate database lookup
                if userId.hasSuffix("-premium") {
                    return Set(["user", "premium"])
                }
                return Set(["user"])
            }
        )
        
        let command = AuthzTestCommand(value: "test")
        let context = CommandContext()
        context.setMetadata("authUserId", value: "user123-premium")
        
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
            requiredRoles: Set(["user"]),
            getUserRoles: { _ in Set() }
        )
        XCTAssertEqual(middleware.priority, .validation)
    }
    
    func testConcurrentAuthorization() async throws {
        // Given
        let middleware = AuthorizationMiddleware(
            requiredRoles: Set(["user"]),
            getUserRoles: { userId in
                // Simulate async role lookup
                try await Task.sleep(nanoseconds: 5_000_000) // 5ms
                return userId.hasPrefix("valid-") ? Set(["user"]) : Set()
            }
        )
        
        // When - Execute multiple authorizations concurrently
        let tasks = (0..<10).map { i in
            Task {
                let command = AuthzTestCommand(value: "test-\(i)")
                let context = CommandContext()
                let userId = i.isMultiple(of: 2) ? "valid-user-\(i)" : "invalid-user-\(i)"
                context.setMetadata("authUserId", value: userId)
                
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
            if i.isMultiple(of: 2) {
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

/// Thread Safety: Test container with single mutable value, used only in test assertions
/// Invariant: Value is accessed only in controlled test environments with predictable ordering
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(value: T) {
        self.value = value
    }
}
