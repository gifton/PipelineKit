import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

// Macro implementations build for the host, so the corresponding module is not available when cross-compiling.
// Cross-compiled tests may still make use of the macro itself in end-to-end tests.
#if canImport(PipelineMacros)
import PipelineMacros

let testMacros: [String: Macro.Type] = [
    "Pipeline": PipelineMacro.self,
]
#endif

final class PipelineMacroTests: XCTestCase {
    
    // MARK: - Basic Functionality Tests
    
    func testBasicActorExpansion() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            }
            """,
            expandedSource: """
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            
                var _executor {
                    DefaultPipeline(handler: handler)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            }
            
            extension UserService: Pipeline {
            }
            """,
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testBasicStructExpansion() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline
            struct OrderService {
                typealias CommandType = ProcessOrderCommand
                let handler = ProcessOrderHandler()
            }
            """,
            expandedSource: """
            struct OrderService {
                typealias CommandType = ProcessOrderCommand
                let handler = ProcessOrderHandler()
            
                private var _executor {
                    DefaultPipeline(handler: handler)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            }
            
            extension OrderService: Pipeline {
            }
            """,
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testFinalClassExpansion() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline
            final class PaymentService {
                typealias CommandType = ProcessPaymentCommand
                let handler = ProcessPaymentHandler()
            }
            """,
            expandedSource: """
            final class PaymentService {
                typealias CommandType = ProcessPaymentCommand
                let handler = ProcessPaymentHandler()
            
                private var _executor {
                    DefaultPipeline(handler: handler)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            }
            """,
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    // MARK: - Configuration Tests
    
    func testContextAwarePipeline() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline(context: .enabled)
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            }
            """,
            expandedSource: """
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            
                var _executor {
                    ContextAwarePipeline(handler: handler)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            }
            """,
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testLimitedConcurrency() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline(concurrency: .limited(10))
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            }
            """,
            expandedSource: """
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            
                var _executor {
                    DefaultPipeline(handler: handler, maxConcurrency: 10)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            }
            """,
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testCustomMaxDepth() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline(maxDepth: 50)
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            }
            """,
            expandedSource: """
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            
                var _executor {
                    DefaultPipeline(handler: handler, maxDepth: 50)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            }
            """,
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testMiddlewareConfiguration() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline(middleware: [AuthMiddleware, ValidationMiddleware])
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            }
            """,
            expandedSource: """
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            
                var _executor {
                    DefaultPipeline(handler: handler)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            
                private func setupMiddleware() throws {
                    try await _executor.addMiddleware(AuthMiddleware())
                    try await _executor.addMiddleware(ValidationMiddleware())
                }
            }
            """,
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testComplexConfiguration() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline(
                concurrency: .limited(5),
                middleware: [AuthMiddleware],
                maxDepth: 25,
                context: .enabled
            )
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            }
            """,
            expandedSource: """
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            
                var _executor {
                    ContextAwarePipeline(handler: handler, maxDepth: 25, maxConcurrency: 5)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            
                private func setupMiddleware() throws {
                    try await _executor.addMiddleware(AuthMiddleware())
                }
            }
            """,
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    // MARK: - Validation Tests
    
    func testInvalidDeclarationType() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline
            class NonFinalService {
                typealias CommandType = SomeCommand
                let handler = SomeHandler()
            }
            """,
            expandedSource: """
            class NonFinalService {
                typealias CommandType = SomeCommand
                let handler = SomeHandler()
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Pipeline can only be applied to actors, structs, or final classes", line: 1, column: 1)
            ],
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testMissingCommandType() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline
            actor IncompleteService {
                let handler = SomeHandler()
            }
            """,
            expandedSource: """
            actor IncompleteService {
                let handler = SomeHandler()
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Missing 'typealias CommandType = SomeCommand' declaration",
                    line: 1,
                    column: 1,
                    fixIts: [
                        FixItSpec(message: "Add CommandType typealias")
                    ]
                )
            ],
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testMissingHandler() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline
            actor IncompleteService {
                typealias CommandType = SomeCommand
            }
            """,
            expandedSource: """
            actor IncompleteService {
                typealias CommandType = SomeCommand
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Missing 'handler' property that conforms to CommandHandler",
                    line: 1,
                    column: 1,
                    fixIts: [
                        FixItSpec(message: "Add handler property")
                    ]
                )
            ],
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testInvalidConcurrencyLimit() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline(concurrency: .limited(0))
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            }
            """,
            expandedSource: """
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            
                var _executor {
                    DefaultPipeline(handler: handler, maxConcurrency: 1)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Concurrency limit must be greater than 0",
                    line: 1,
                    column: 24,
                    fixIts: [
                        FixItSpec(message: "Set concurrency limit to 1")
                    ]
                )
            ],
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    func testInvalidMaxDepth() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline(maxDepth: -5)
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            }
            """,
            expandedSource: """
            actor UserService {
                typealias CommandType = CreateUserCommand
                let handler = CreateUserHandler()
            
                var _executor {
                    DefaultPipeline(handler: handler, maxDepth: 1)
                }
            
                public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result {
                    return try await _executor.execute(command, metadata: metadata)
                }
            
                public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result] {
                    return try await _executor.batchExecute(commands, metadata: metadata)
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Max depth must be a positive integer",
                    line: 1,
                    column: 21,
                    fixIts: [
                        FixItSpec(message: "Set max depth to 1")
                    ]
                )
            ],
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
    
    // MARK: - Edge Cases
    
    func testEmptyActor() throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            """
            @Pipeline
            actor EmptyService {
            }
            """,
            expandedSource: """
            actor EmptyService {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Missing 'typealias CommandType = SomeCommand' declaration", 
                    line: 1, 
                    column: 1,
                    fixIts: [
                        FixItSpec(message: "Add CommandType typealias")
                    ]
                ),
                DiagnosticSpec(
                    message: "Missing 'handler' property that conforms to CommandHandler", 
                    line: 1, 
                    column: 1,
                    fixIts: [
                        FixItSpec(message: "Add handler property")
                    ]
                )
            ],
            macros: testMacros
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
}

// MARK: - Helper Extensions

extension PipelineMacroTests {
    
    /// Helper to create a simple test case with expected expansion
    private func assertPipelineExpansion(
        input: String,
        expected: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
#if canImport(PipelineMacros)
        assertMacroExpansion(
            input,
            expandedSource: expected,
            macros: testMacros,
            file: file,
            line: line
        )
#else
        throw XCTSkip("macros are only supported when running tests for the host platform")
#endif
    }
}