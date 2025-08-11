import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

// NOTE: MiddlewareRegistry has been removed in the refactoring
// These tests are kept for reference but commented out
/*
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
        await registry.register("custom", aliases: ["myMiddleware"]) { config in
            factoryCalledBox.value = true
            return TestMiddleware(name: "custom", config: config ?? [:])
        }
        
        // Then
        let isRegistered = await registry.isRegistered("custom")
        XCTAssertTrue(isRegistered)
        
        let aliasRegistered = await registry.isRegistered("myMiddleware")
        XCTAssertTrue(aliasRegistered)
        
        // Create instance
        let middleware = try await registry.create("custom")
        XCTAssertNotNil(middleware)
        XCTAssertTrue(factoryCalledBox.value)
    }
    
    func testFactoryWithConfiguration() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        let config = [
            "maxRetries": 3,
            "timeout": 30.0
        ] as [String: Any]
        
        // When
        await registry.register("configured") { providedConfig in
            TestMiddleware(name: "configured", config: providedConfig ?? [:])
        }
        
        // Then
        let middleware = try await registry.create("configured", config: config)
        XCTAssertNotNil(middleware)
        
        // Verify config was passed
        if let testMiddleware = middleware as? TestMiddleware {
            XCTAssertEqual(testMiddleware.config["maxRetries"] as? Int, 3)
            XCTAssertEqual(testMiddleware.config["timeout"] as? Double, 30.0)
        } else {
            XCTFail("Expected TestMiddleware")
        }
    }
    
    func testUnregisteredMiddlewareThrows() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        
        // When/Then
        do {
            _ = try await registry.create("nonexistent")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is MiddlewareRegistryError)
        }
    }
    
    func testRegistryClearing() async throws {
        // Given
        let registry = MiddlewareRegistry()
        await registry.register("test") { _ in TestMiddleware(name: "test") }
        
        // When
        await registry.clear()
        
        // Then
        let isRegistered = await registry.isRegistered("test")
        XCTAssertFalse(isRegistered)
    }
    
    func testPipelineTemplateRegistration() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        let template = WebAPIPipelineTemplate()
        
        // When
        await registry.registerTemplate("webapi", template: template)
        
        // Then
        let retrieved = await registry.template("webapi")
        XCTAssertNotNil(retrieved)
        XCTAssertTrue(retrieved is WebAPIPipelineTemplate)
    }
    
    func testBuildPipelineFromTemplate() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        let template = WebAPIPipelineTemplate()
        await registry.registerTemplate("webapi", template: template)
        
        let handler = TestHandler()
        let config = ["apiKey": "test123"]
        
        // When
        let pipeline = try await registry.buildPipeline(
            from: "webapi",
            handler: handler,
            config: config
        )
        
        // Then
        XCTAssertNotNil(pipeline)
        // Pipeline should have been built with template's middleware
    }
    
    func testConcurrentRegistration() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        let registrationCount = 100
        
        // When - register many middleware concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<registrationCount {
                group.addTask {
                    await registry.register("concurrent-\(i)") { _ in
                        TestMiddleware(name: "concurrent-\(i)")
                    }
                }
            }
        }
        
        // Then - all should be registered
        for i in 0..<registrationCount {
            let isRegistered = await registry.isRegistered("concurrent-\(i)")
            XCTAssertTrue(isRegistered)
        }
    }
    
    func testConcurrentCreation() async throws {
        // Given
        let registry = MiddlewareRegistry.shared
        var creationCount = 0
        let lock = NSLock()
        
        await registry.register("shared") { _ in
            lock.lock()
            creationCount += 1
            lock.unlock()
            return TestMiddleware(name: "shared")
        }
        
        // When - create many instances concurrently
        let instances = await withTaskGroup(of: (any Middleware)?.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try? await registry.create("shared")
                }
            }
            
            var results: [any Middleware] = []
            for await instance in group {
                if let instance = instance {
                    results.append(instance)
                }
            }
            return results
        }
        
        // Then
        XCTAssertEqual(instances.count, 100)
        XCTAssertEqual(creationCount, 100) // Factory called for each creation
    }
}

// MARK: - Test Helpers

private struct TestMiddleware: Middleware {
    let name: String
    let config: [String: Any]
    let priority = ExecutionPriority.processing
    
    init(name: String, config: [String: Any] = [:]) {
        self.name = name
        self.config = config
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        try await next(command, context)
    }
}

private struct TestHandler: CommandHandler {
    typealias CommandType = TestCommand
    
    func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
        "Handled"
    }
}

private struct TestCommand: Command {
    typealias Result = String
}

private class Box<T> {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}

private struct WebAPIPipelineTemplate: PipelineTemplate {
    func build<T: Command, H: CommandHandler>(
        handler: H,
        config: [String: Any]?
    ) async throws -> any Pipeline where H.CommandType == T {
        try await PipelineBuilder(handler: handler)
            .with(TestMiddleware(name: "auth"))
            .with(TestMiddleware(name: "rateLimit"))
            .with(TestMiddleware(name: "validation"))
            .build()
    }
}
*/
