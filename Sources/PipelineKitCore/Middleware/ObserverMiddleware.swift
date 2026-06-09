import Foundation

/// A middleware that observes commands without participating in the next-chain.
///
/// `ObserverMiddleware` is for components that perform side effects — logging,
/// metrics, audit, validation — by inspecting the command and context, but that
/// neither transform the result nor decide whether to proceed. Unlike a general
/// `Middleware`, an observer never receives (or calls) a `next` closure.
///
/// ## Two ways to use an observer
/// 1. **In a normal pipeline.** The default `execute` runs `observe(_:context:)`
///    and then forwards to `next`, so an observer drops into any pipeline chain.
/// 2. **In parallel.** `ParallelMiddlewareWrapper` runs a set of observers
///    concurrently and then executes the command once. Because observers have no
///    `next`, there is no sentinel-throw machinery.
///
/// ## Failure semantics
/// `observe` is `async throws`. Throwing rejects the command: in a normal chain
/// the error propagates instead of calling `next`; in a parallel wrapper a throw
/// cancels the sibling observers and fails the command. Observers that only
/// record side effects simply never throw.
public protocol ObserverMiddleware: Middleware {
    /// Observes a command and its context, performing side effects.
    ///
    /// - Parameters:
    ///   - command: The command being executed.
    ///   - context: The shared command context.
    /// - Throws: Any error; throwing rejects the command (see Failure semantics).
    func observe<T: Command>(_ command: T, context: CommandContext) async throws
}

public extension ObserverMiddleware {
    /// Observers default to the observability band when used in a sequential chain.
    var priority: ExecutionPriority { .observability }

    /// Bridges `observe` into the `Middleware` chain: observe, then pass through.
    ///
    /// Calls `observe` once and, if it does not throw, forwards to `next` exactly
    /// once — satisfying `NextGuard`'s single-call contract on the success path.
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        try await observe(command, context: context)
        return try await next(command, context)
    }
}
