import XCTest
import Foundation
@testable import PipelineKit

final class AuthenticationMiddlewareTestsV2: XCTestCase {
    
    func testSuccessfulAuthentication() async throws {
        // Given
        let middleware = AuthenticationMiddleware { token in
            guard token == "valid-token" else {
                throw AuthenticationError.invalidToken
            }
            return "user-123"
        }
        
        let command = AuthTestCommandV2(value: "test")
        let metadata = StandardCommandMetadata(userId: "valid-token")
        let context = CommandContext(metadata: metadata)
        
        var middlewareExecuted = false
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            middlewareExecuted = true
            
            // Verify authenticated user ID is set
            let userId = await ctx.get(AuthenticatedUserKey.self)
            XCTAssertEqual(userId, "user-123")
            
            return cmd.value
        }
        
        // Then
        XCTAssertTrue(middlewareExecuted)
        XCTAssertEqual(result, "test")
    }
    
    func testAuthenticationFailureWithInvalidToken() async throws {
        // Given
        let middleware = AuthenticationMiddleware { token in
            guard token == "valid-token" else {
                throw AuthenticationError.invalidToken
            }
            return "user-123"
        }
        
        let command = AuthTestCommandV2(value: "test")
        let metadata = StandardCommandMetadata(userId: "invalid-token")
        let context = CommandContext(metadata: metadata)
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Handler should not be called with invalid token")
                return ""
            }
            XCTFail("Should throw authentication error")
        } catch {
            XCTAssertTrue(error is AuthenticationError)
        }
    }
    
    func testAuthenticationFailureWithMissingToken() async throws {
        // Given
        let middleware = AuthenticationMiddleware { token in
            guard token != nil else {
                throw AuthenticationError.invalidToken
            }
            return "user-123"
        }
        
        let command = AuthTestCommandV2(value: "test")
        let metadata = StandardCommandMetadata() // No userId
        let context = CommandContext(metadata: metadata)
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Handler should not be called without token")
                return ""
            }
            XCTFail("Should throw authentication error")
        } catch {
            XCTAssertTrue(error is AuthenticationError)
        }
    }
    
    func testCustomAuthenticator() async throws {
        // Given
        var authenticatorCalled = false
        let middleware = AuthenticationMiddleware { token in
            authenticatorCalled = true
            
            // Simulate API key validation
            if token?.hasPrefix("api-key-") == true {
                return String(token!.dropFirst(8)) // Extract user from api-key-{userId}
            }
            throw AuthenticationError.invalidToken
        }
        
        let command = AuthTestCommandV2(value: "test")
        let metadata = StandardCommandMetadata(userId: "api-key-user456")
        let context = CommandContext(metadata: metadata)
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            let userId = await ctx.get(AuthenticatedUserKey.self)
            XCTAssertEqual(userId, "user456")
            return cmd.value
        }
        
        // Then
        XCTAssertTrue(authenticatorCalled)
        XCTAssertEqual(result, "test")
    }
    
    func testAuthenticationPriority() {
        let middleware = AuthenticationMiddleware { _ in "user" }
        XCTAssertEqual(middleware.priority, .authentication)
    }
    
    func testConcurrentAuthentication() async throws {
        // Given
        let middleware = AuthenticationMiddleware { token in
            // Simulate async authentication
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            guard token == "valid-token" else {
                throw AuthenticationError.invalidToken
            }
            return "user-\(UUID().uuidString)"
        }
        
        // When - Execute multiple authentications concurrently
        let tasks = (0..<10).map { i in
            Task {
                let command = AuthTestCommandV2(value: "test-\(i)")
                let metadata = StandardCommandMetadata(userId: "valid-token")
                let context = CommandContext(metadata: metadata)
                
                return try await middleware.execute(command, context: context) { cmd, ctx in
                    // Each should have a unique user ID
                    let userId = await ctx.get(AuthenticatedUserKey.self)
                    XCTAssertNotNil(userId)
                    XCTAssertTrue(userId!.hasPrefix("user-"))
                    return cmd.value
                }
            }
        }
        
        // Then - All should succeed
        for (i, task) in tasks.enumerated() {
            let result = try await task.value
            XCTAssertEqual(result, "test-\(i)")
        }
    }
}

// Test support types
private struct AuthTestCommandV2: Command {
    typealias Result = String
    let value: String
    
    func execute() async throws -> String {
        return value
    }
}