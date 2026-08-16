import Foundation
import PipelineKitCore

/// Internal helper to assemble middleware chains consistently across pipelines.
///
/// Builds a single `@Sendable` closure by wrapping the provided `final` closure
/// with each middleware in reverse order. Optionally injects cancellation checks
/// before each middleware execution to mirror existing pipeline behavior.
///
/// ## Conditional Middleware Support
///
/// When a middleware conforms to `ConditionalMiddleware`, the chain builder
/// inserts a `shouldActivate` check before invoking the middleware. If the
/// check returns `false`, the middleware is bypassed and execution continues
/// to the next component in the chain.
enum MiddlewareChainBuilder {
    /// Build a middleware chain from a ContiguousArray without copying.
    static func build<T: Command>(
        middlewares: ContiguousArray<any Middleware>,
        insertCancellationChecks: Bool,
        final: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) -> @Sendable (T, CommandContext) async throws -> T.Result {
        var chain = final
        if !middlewares.isEmpty {
            for i in stride(from: middlewares.count - 1, through: 0, by: -1) {
                let middleware = middlewares[i]
                let previous = chain
                let isUnsafe = middleware is any UnsafeMiddleware
                let suppress = (middleware is any NextGuardWarningSuppressing)
                let middlewareName = String(describing: type(of: middleware))

                // Check if middleware is conditional and wrap with activation check
                let conditionalMiddleware = middleware as? any ConditionalMiddleware

                chain = { (cmd: T, ctx: CommandContext) in
                    if insertCancellationChecks {
                        try Task.checkCancellation(context: "Pipeline execution cancelled at middleware: \(middlewareName)")
                    }

                    // If conditional, check shouldActivate before executing
                    if let conditional = conditionalMiddleware {
                        guard conditional.shouldActivate(for: cmd, context: ctx) else {
                            // Skip this middleware, pass directly to next in chain
                            return try await previous(cmd, ctx)
                        }
                    }

                    // Unsafe middleware opts out of NextGuard entirely
                    if isUnsafe {
                        return try await middleware.execute(cmd, context: ctx, next: previous)
                    }

                    // Create NextGuard lazily, only when middleware will actually execute
                    let nextGuard = NextGuard<T>(
                        previous,
                        identifier: middlewareName,
                        suppressDeinitWarning: suppress
                    )
                    do {
                        return try await middleware.execute(cmd, context: ctx, next: nextGuard.callAsFunction)
                    } catch {
                        // An error exit is caller-visible — never a silently
                        // dropped chain; keep the debug deinit warning quiet
                        nextGuard.markErrorExit()
                        throw error
                    }
                }
            }
        }
        return chain
    }

    /// Build a middleware chain from a standard Array.
    static func build<T: Command>(
        middlewares: [any Middleware],
        insertCancellationChecks: Bool,
        final: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) -> @Sendable (T, CommandContext) async throws -> T.Result {
        var chain = final
        for i in stride(from: middlewares.count - 1, through: 0, by: -1) {
            let middleware = middlewares[i]
            let previous = chain
            let isUnsafe = middleware is any UnsafeMiddleware
            let suppress = (middleware is any NextGuardWarningSuppressing)
            let middlewareName = String(describing: type(of: middleware))

            // Check if middleware is conditional and wrap with activation check
            let conditionalMiddleware = middleware as? any ConditionalMiddleware

            chain = { (cmd: T, ctx: CommandContext) in
                if insertCancellationChecks {
                    try Task.checkCancellation(context: "Pipeline execution cancelled at middleware: \(middlewareName)")
                }

                // If conditional, check shouldActivate before executing
                if let conditional = conditionalMiddleware {
                    guard conditional.shouldActivate(for: cmd, context: ctx) else {
                        // Skip this middleware, pass directly to next in chain
                        return try await previous(cmd, ctx)
                    }
                }

                // Unsafe middleware opts out of NextGuard entirely
                if isUnsafe {
                    return try await middleware.execute(cmd, context: ctx, next: previous)
                }

                // Create NextGuard lazily, only when middleware will actually execute
                let nextGuard = NextGuard<T>(
                    previous,
                    identifier: middlewareName,
                    suppressDeinitWarning: suppress
                )
                do {
                    return try await middleware.execute(cmd, context: ctx, next: nextGuard.callAsFunction)
                } catch {
                    // An error exit is caller-visible — never a silently
                    // dropped chain; keep the debug deinit warning quiet
                    nextGuard.markErrorExit()
                    throw error
                }
            }
        }
        return chain
    }
}
