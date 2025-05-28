import XCTest
@testable import PipelineKit

final class CommandBusTests: XCTestCase {
    
    struct AddNumbersCommand: Command {
        typealias Result = Int
        let a: Int
        let b: Int
    }
    
    struct AddNumbersHandler: CommandHandler {
        typealias CommandType = AddNumbersCommand
        
        func handle(_ command: AddNumbersCommand) async throws -> Int {
            return command.a + command.b
        }
    }
    
    struct MultiplyCommand: Command {
        typealias Result = Int
        let value: Int
        let multiplier: Int
    }
    
    struct MultiplyHandler: CommandHandler {
        typealias CommandType = MultiplyCommand
        
        func handle(_ command: MultiplyCommand) async throws -> Int {
            return command.value * command.multiplier
        }
    }
    
    struct LoggingMiddleware: Middleware {
        let logs: Actor<[String]>
        
        init(logs: Actor<[String]>) {
            self.logs = logs
        }
        
        func execute<T: Command>(
            _ command: T,
            metadata: CommandMetadata,
            next: @Sendable (T, CommandMetadata) async throws -> T.Result
        ) async throws -> T.Result {
            await logs.append("Before: \(String(describing: T.self))")
            let result = try await next(command, metadata)
            await logs.append("After: \(String(describing: T.self))")
            return result
        }
    }
    
    actor Actor<T: Sendable>: Sendable {
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
        
        func append(_ element: String) where T == [String] {
            value.append(element)
        }
    }
    
    func testBasicCommandExecution() async throws {
        let bus = CommandBus()
        let handler = AddNumbersHandler()
        
        try await bus.register(AddNumbersCommand.self, handler: handler)
        
        let result = try await bus.send(AddNumbersCommand(a: 5, b: 3))
        XCTAssertEqual(result, 8)
    }
    
    func testMultipleHandlers() async throws {
        let bus = CommandBus()
        
        try await bus.register(AddNumbersCommand.self, handler: AddNumbersHandler())
        try await bus.register(MultiplyCommand.self, handler: MultiplyHandler())
        
        let addResult = try await bus.send(AddNumbersCommand(a: 10, b: 5))
        let multiplyResult = try await bus.send(MultiplyCommand(value: 4, multiplier: 3))
        
        XCTAssertEqual(addResult, 15)
        XCTAssertEqual(multiplyResult, 12)
    }
    
    func testHandlerNotFound() async throws {
        let bus = CommandBus()
        
        do {
            _ = try await bus.send(AddNumbersCommand(a: 1, b: 2))
            XCTFail("Expected error")
        } catch let error as CommandBusError {
            if case .handlerNotFound = error {
                // Success
            } else {
                XCTFail("Wrong error type")
            }
        }
    }
    
    func testMiddlewareExecution() async throws {
        let bus = CommandBus()
        let logs = Actor<[String]>([])
        let middleware = LoggingMiddleware(logs: logs)
        
        try await bus.addMiddleware(middleware)
        try await bus.register(AddNumbersCommand.self, handler: AddNumbersHandler())
        
        let result = try await bus.send(AddNumbersCommand(a: 2, b: 3))
        
        XCTAssertEqual(result, 5)
        
        let logEntries = await logs.get()
        XCTAssertEqual(logEntries.count, 2)
        XCTAssertTrue(logEntries[0].contains("Before"))
        XCTAssertTrue(logEntries[1].contains("After"))
    }
    
    func testCommandBusBuilder() async throws {
        let builder = CommandBusBuilder()
        let handler = AddNumbersHandler()
        
        let bus = try await builder
            .with(AddNumbersCommand.self, handler: handler)
            .build()
        
        let result = try await bus.send(AddNumbersCommand(a: 7, b: 8))
        XCTAssertEqual(result, 15)
    }
}