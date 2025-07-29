import Foundation

/// Optimized fast path executor using generic specialization to eliminate type erasure overhead
public struct FastPathExecutorV2 {
    
    /// Direct execution - no middleware
    public struct DirectExecutor<C: Command>: Sendable {
        private let execute: @Sendable (C, CommandContext, @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result
        
        init() {
            self.execute = { command, _, handler in
                try await handler(command)
            }
        }
        
        public func execute(_ command: C, context: CommandContext, handler: @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result {
            try await self.execute(command, context, handler)
        }
    }
    
    /// Single middleware executor
    public struct SingleMiddlewareExecutor<C: Command, M: Middleware>: Sendable {
        private let middleware: M
        private let execute: @Sendable (C, CommandContext, M, @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result
        
        init(middleware: M) {
            self.middleware = middleware
            self.execute = { command, context, middleware, handler in
                try await middleware.execute(command, context: context) { cmd, ctx in
                    try await handler(cmd)
                }
            }
        }
        
        public func execute(_ command: C, context: CommandContext, handler: @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result {
            try await self.execute(command, context, middleware, handler)
        }
    }
    
    /// Double middleware executor
    public struct DoubleMiddlewareExecutor<C: Command, M1: Middleware, M2: Middleware>: Sendable {
        private let middleware1: M1
        private let middleware2: M2
        private let execute: @Sendable (C, CommandContext, M1, M2, @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result
        
        init(middleware1: M1, middleware2: M2) {
            self.middleware1 = middleware1
            self.middleware2 = middleware2
            self.execute = { command, context, mw1, mw2, handler in
                try await mw1.execute(command, context: context) { cmd1, ctx1 in
                    try await mw2.execute(cmd1, context: ctx1) { cmd2, ctx2 in
                        try await handler(cmd2)
                    }
                }
            }
        }
        
        public func execute(_ command: C, context: CommandContext, handler: @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result {
            try await self.execute(command, context, middleware1, middleware2, handler)
        }
    }
    
    /// Triple middleware executor
    public struct TripleMiddlewareExecutor<C: Command, M1: Middleware, M2: Middleware, M3: Middleware>: Sendable {
        private let middleware1: M1
        private let middleware2: M2
        private let middleware3: M3
        private let execute: @Sendable (C, CommandContext, M1, M2, M3, @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result
        
        init(middleware1: M1, middleware2: M2, middleware3: M3) {
            self.middleware1 = middleware1
            self.middleware2 = middleware2
            self.middleware3 = middleware3
            self.execute = { command, context, mw1, mw2, mw3, handler in
                try await mw1.execute(command, context: context) { cmd1, ctx1 in
                    try await mw2.execute(cmd1, context: ctx1) { cmd2, ctx2 in
                        try await mw3.execute(cmd2, context: ctx2) { cmd3, ctx3 in
                            try await handler(cmd3)
                        }
                    }
                }
            }
        }
        
        public func execute(_ command: C, context: CommandContext, handler: @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result {
            try await self.execute(command, context, middleware1, middleware2, middleware3, handler)
        }
    }
}

/// Type-erased wrapper for fast path executors
public protocol AnyFastPathExecutor: Sendable {
    func execute<C: Command>(_ command: C, context: CommandContext, handler: @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result
}

/// Type-erased direct executor
public struct AnyDirectExecutor: AnyFastPathExecutor {
    private let executeFunc: @Sendable (Any, CommandContext, @escaping @Sendable (Any) async throws -> Any) async throws -> Any
    
    init<C: Command>(executor: FastPathExecutorV2.DirectExecutor<C>) {
        self.executeFunc = { command, context, handler in
            guard let typedCommand = command as? C else {
                throw OptimizationError.typeMismatch
            }
            let result = try await executor.execute(typedCommand, context: context) { cmd in
                let handlerResult = try await handler(cmd)
                guard let typedResult = handlerResult as? C.Result else {
                    throw OptimizationError.typeMismatch
                }
                return typedResult
            }
            return result
        }
    }
    
    public func execute<C: Command>(_ command: C, context: CommandContext, handler: @escaping @Sendable (C) async throws -> C.Result) async throws -> C.Result {
        let result = try await executeFunc(command, context) { cmd in
            guard let typedCmd = cmd as? C else {
                throw OptimizationError.typeMismatch
            }
            return try await handler(typedCmd)
        }
        guard let typedResult = result as? C.Result else {
            throw OptimizationError.typeMismatch
        }
        return typedResult
    }
}

/// Factory for creating optimized fast path executors
public enum FastPathExecutorFactory {
    
    /// Creates an optimized executor for the given middleware configuration
    public static func createExecutor(for middleware: [any Middleware]) -> AnyFastPathExecutor? {
        switch middleware.count {
        case 0:
            // For now, return nil as we need the command type
            // In practice, this would be created with the specific command type
            return nil
        case 1:
            // Single middleware - would need specific types
            return nil
        case 2:
            // Double middleware - would need specific types
            return nil
        case 3:
            // Triple middleware - would need specific types
            return nil
        default:
            // Too many middleware for fast path
            return nil
        }
    }
    
    /// Creates a direct executor for a specific command type
    public static func createDirectExecutor<C: Command>(for commandType: C.Type) -> FastPathExecutorV2.DirectExecutor<C> {
        return FastPathExecutorV2.DirectExecutor<C>()
    }
    
    /// Creates a single middleware executor
    public static func createSingleExecutor<C: Command, M: Middleware>(
        for commandType: C.Type,
        middleware: M
    ) -> FastPathExecutorV2.SingleMiddlewareExecutor<C, M> {
        return FastPathExecutorV2.SingleMiddlewareExecutor<C, M>(middleware: middleware)
    }
    
    /// Creates a double middleware executor
    public static func createDoubleExecutor<C: Command, M1: Middleware, M2: Middleware>(
        for commandType: C.Type,
        middleware1: M1,
        middleware2: M2
    ) -> FastPathExecutorV2.DoubleMiddlewareExecutor<C, M1, M2> {
        return FastPathExecutorV2.DoubleMiddlewareExecutor<C, M1, M2>(
            middleware1: middleware1,
            middleware2: middleware2
        )
    }
    
    /// Creates a triple middleware executor
    public static func createTripleExecutor<C: Command, M1: Middleware, M2: Middleware, M3: Middleware>(
        for commandType: C.Type,
        middleware1: M1,
        middleware2: M2,
        middleware3: M3
    ) -> FastPathExecutorV2.TripleMiddlewareExecutor<C, M1, M2, M3> {
        return FastPathExecutorV2.TripleMiddlewareExecutor<C, M1, M2, M3>(
            middleware1: middleware1,
            middleware2: middleware2,
            middleware3: middleware3
        )
    }
}