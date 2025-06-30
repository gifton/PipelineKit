import XCTest
@testable import PipelineKit

final class MiddlewareRegistryTests: XCTestCase {
    
    override func setUp() async throws {
        // Clear registry before each test
        await MiddlewareRegistry.shared.clear()
    }
    
    func testRegistryDefaults() async throws {
        // Given
        let registry = MiddlewareRegistry()
        
        // Allow time for default registration
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Then - verify default middleware are registered
        let authRegistered = await registry.isRegistered("authentication")
        XCTAssertTrue(authRegistered)
        
        let authzRegistered = await registry.isRegistered("authorization")
        XCTAssertTrue(authzRegistered)
        
        let validationRegistered = await registry.isRegistered("validation")
        XCTAssertTrue(validationRegistered)
        
        let rateLimitRegistered = await registry.isRegistered("rateLimiting")
        XCTAssertTrue(rateLimitRegistered)
        
        let resilientRegistered = await registry.isRegistered("resilient")
        XCTAssertTrue(resilientRegistered)
        
        // Verify aliases work
        let authAliasRegistered = await registry.isRegistered("auth")
        XCTAssertTrue(authAliasRegistered)
        
        let authzAliasRegistered = await registry.isRegistered("authz")
        XCTAssertTrue(authzAliasRegistered)
        
        let rateLimitAliasRegistered = await registry.isRegistered("rateLimit")
        XCTAssertTrue(rateLimitAliasRegistered)
    }
    
    func testCustomMiddlewareRegistration() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        let factoryCalledBox = Box(false)
        
        // When
        await registry.register("custom") {
            factoryCalledBox.value = true
            return RegistryTestMiddleware()
        }
        
        // Then
        let isRegistered = await registry.isRegistered("custom")
        XCTAssertTrue(isRegistered)
        
        // Creating middleware should call factory
        let middleware = try await registry.create("custom")
        XCTAssertNotNil(middleware)
        XCTAssertTrue(factoryCalledBox.value)
        XCTAssertTrue(middleware is RegistryTestMiddleware)
    }
    
    func testMissingMiddlewareReturnsNil() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        
        // When
        let middleware = try await registry.create("nonexistent")
        
        // Then
        XCTAssertNil(middleware)
    }
    
    func testTemplateWithMissingMiddleware() async throws {
        // Given
        let template = WebAPIPipelineTemplate(
            configuration: .init(
                enableCaching: true,
                enableMetrics: true
            )
        )
        
        // Clear registry to simulate missing middleware
        await MiddlewareRegistry.shared.clear()
        
        // When - create pipeline (should not crash)
        let pipeline = try await template.build(with: RegistryTestHandler())
        
        // Then - pipeline should be created successfully
        XCTAssertNotNil(pipeline)
        
        // Note: In a real test, we'd capture console output to verify warnings
    }
    
    func testRegistryAliases() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        await registry.register("original") { RegistryTestMiddleware() }
        
        // When
        await registry.alias("shortcut", for: "original")
        
        // Then
        let isRegistered = await registry.isRegistered("shortcut")
        XCTAssertTrue(isRegistered)
        let middleware = try await registry.create("shortcut")
        XCTAssertNotNil(middleware)
        XCTAssertTrue(middleware is RegistryTestMiddleware)
    }
    
    func testListRegisteredMiddleware() async throws {
        // Given
        let registry = MiddlewareRegistry()
        await registry.register("middleware1") { RegistryTestMiddleware() }
        await registry.register("middleware2") { RegistryTestMiddleware() }
        await registry.register("middleware3") { RegistryTestMiddleware() }
        
        // When
        let registered = await registry.listRegistered()
        
        // Then
        XCTAssertTrue(registered.contains("middleware1"))
        XCTAssertTrue(registered.contains("middleware2"))
        XCTAssertTrue(registered.contains("middleware3"))
        XCTAssertEqual(registered.sorted(), registered) // Should be sorted
    }
    
    func testCaseInsensitiveRegistration() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        await registry.register("TestMiddleware") { RegistryTestMiddleware() }
        
        // Then - all case variations should work
        let reg1 = await registry.isRegistered("TestMiddleware")
        XCTAssertTrue(reg1)
        
        let reg2 = await registry.isRegistered("testmiddleware")
        XCTAssertTrue(reg2)
        
        let reg3 = await registry.isRegistered("TESTMIDDLEWARE")
        XCTAssertTrue(reg3)
        
        let reg4 = await registry.isRegistered("testMiddleware")
        XCTAssertTrue(reg4)
    }
}

// Test support types
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}

private struct RegistryTestMiddleware: Middleware {
    let priority: ExecutionPriority = .custom
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        try await next(command, context)
    }
}

private struct RegistryTestCommand: Command {
    typealias Result = String
    func execute() async throws -> String {
        "test"
    }
}

private struct RegistryTestHandler: CommandHandler {
    typealias CommandType = RegistryTestCommand
    
    func handle(_ command: RegistryTestCommand) async throws -> String {
        try await command.execute()
    }
}