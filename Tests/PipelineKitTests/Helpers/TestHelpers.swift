//
//  TestHelpers.swift
//  PipelineKit
//
//  Test utilities for context-based testing
//

import Foundation
@testable import PipelineKit

// MARK: - Test Actor for Thread-Safe Collection

/// Helper actor for thread-safe test data collection
actor TestActor<T: Sendable>: Sendable {
    private var value: T
    
    init(_ value: T) {
        self.value = value
    }
    
    func get() -> T {
        value
    }
    
    func set(_ newValue: T) {
        value = newValue
    }
    
    func increment() where T == Int {
        value += 1
    }
    
    func incrementCount(for key: String) where T == [String: Int] {
        value[key, default: 0] += 1
    }
}

// MARK: - Test Command Metadata

struct TestCommandMetadata: CommandMetadata, @unchecked Sendable {
    let id: UUID
    let userId: String?
    let correlationId: String?
    let timestamp: Date
    let additionalData: [String: Any]
    
    init(
        id: UUID = UUID(),
        userId: String? = "test-user",
        correlationId: String? = UUID().uuidString,
        timestamp: Date = Date(),
        additionalData: [String: Any] = [:]
    ) {
        self.id = id
        self.userId = userId
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.additionalData = additionalData
    }
}

// MARK: - CommandContext Test Extensions

// MARK: - Test Context Keys

struct TestCustomValueKey: ContextKey {
    typealias Value = String
}

struct TestNumberKey: ContextKey {
    typealias Value = Int
}

struct TestMetricsKey: ContextKey {
    typealias Value = MockMetricsCollector
}

struct TestEncryptionServiceKey: ContextKey {
    typealias Value = MockEncryptionService
}

extension CommandContext {
    static func test(
        userId: String? = "test-user",
        correlationId: String = UUID().uuidString,
        additionalData: [String: Any] = [:],
        customKeys: [String: Any] = [:]
    ) async -> CommandContext {
        let metadata = TestCommandMetadata(
            userId: userId,
            correlationId: correlationId,
            additionalData: additionalData
        )
        
        let context = CommandContext(metadata: metadata)
        
        // Custom keys would need to be set with proper ContextKey types
        
        return context
    }
    
    static func testWithMetrics() async -> CommandContext {
        let context = await test()
        await context.set(MockMetricsCollector(), for: TestMetricsKey.self)
        return context
    }
    
    static func testWithEncryption() async -> CommandContext {
        let context = await test()
        await context.set(MockEncryptionService(), for: TestEncryptionServiceKey.self)
        return context
    }
}

// MARK: - Test Commands

struct TestCommand: Command {
    typealias Result = String
    
    let value: String
    let shouldFail: Bool
    
    init(value: String = "test", shouldFail: Bool = false) {
        self.value = value
        self.shouldFail = shouldFail
    }
    
    func execute() async throws -> String {
        if shouldFail {
            throw TestError.commandFailed
        }
        return value
    }
}

struct AsyncTestCommand: Command {
    typealias Result = Int
    
    let delay: TimeInterval
    let value: Int
    
    init(delay: TimeInterval = 0.1, value: Int = 42) {
        self.delay = delay
        self.value = value
    }
    
    func execute() async throws -> Int {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return value
    }
}

// MARK: - Test Middleware

final class TestMiddleware: Middleware, @unchecked Sendable {
    var executionCount = 0
    var lastCommand: (any Command)?
    var lastContext: CommandContext?
    let priority: ExecutionPriority = .custom
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        executionCount += 1
        lastCommand = command
        lastContext = context
        
        return try await next(command, context)
    }
}

final class FailingMiddleware: Middleware, @unchecked Sendable {
    let error: Error
    let priority: ExecutionPriority = .custom
    
    init(error: Error = TestError.middlewareFailed) {
        self.error = error
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        throw error
    }
}

final class ModifyingMiddleware<Key: ContextKey>: Middleware, @unchecked Sendable {
    let keyType: Key.Type
    let value: Key.Value
    let priority: ExecutionPriority = .custom
    
    init(key: Key.Type, value: Key.Value) {
        self.keyType = key
        self.value = value
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        await context.set(value, for: keyType)
        return try await next(command, context)
    }
}

// MARK: - Test Errors

enum TestError: Error {
    case commandFailed
    case middlewareFailed
    case pipelineFailed
    case validationFailed
    case unauthorized
    case rateLimitExceeded
}

// MARK: - Test Utilities

struct TestConstants {
    static let defaultUserId = "test-user-123"
    static let defaultCorrelationId = "test-correlation-123"
    static let defaultTimeout: TimeInterval = 5.0
}

extension CommandContext {
    func assertHasMetadata() async throws -> CommandMetadata {
        return await self.commandMetadata
    }
    
    // Metrics assertion would need proper ContextKey
}

// MARK: - Mock Services

final class MockMetricsCollector: @unchecked Sendable {
    private(set) var recordedMetrics: [(name: String, value: Double, tags: [String: String])] = []
    
    func record(metric: String, value: Double, tags: [String: String]) {
        recordedMetrics.append((name: metric, value: value, tags: tags))
    }
    
    func increment(metric: String, tags: [String: String]) {
        record(metric: metric, value: 1.0, tags: tags)
    }
    
    func timing(metric: String, duration: TimeInterval, tags: [String: String]) {
        record(metric: metric, value: duration, tags: tags)
    }
}

final class MockEncryptionService: @unchecked Sendable {
    func encrypt<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return "ENCRYPTED:\(data.base64EncodedString())".data(using: .utf8)!
    }
    
    func decrypt<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let string = String(data: data, encoding: .utf8)!
        guard string.hasPrefix("ENCRYPTED:") else {
            throw TestError.validationFailed
        }
        let base64 = String(string.dropFirst("ENCRYPTED:".count))
        let realData = Data(base64Encoded: base64)!
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: realData)
    }
}