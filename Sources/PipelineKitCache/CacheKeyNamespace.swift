import PipelineKit

/// Shared cache identity framing. `testNamespaceEncodingIsUnambiguous` exercises
/// empty fields, separators, Unicode, and independently differing type fields.
internal enum CacheKeyNamespace {
    static func encode(commandType: String, resultType: String, middleware: String, callerKey: String) -> String {
        // A byte count followed by ':' makes each field's boundary independent of its contents.
        [commandType, resultType, middleware, callerKey]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
    }

    static func generate<T: Command>(
        for command: T,
        context: CommandContext,
        middleware: String,
        using generator: any CacheKeyGenerator
    ) async -> String {
        let callerKey = await generator.generateKey(for: command, context: context, middleware: middleware)
        return encode(
            commandType: String(reflecting: T.self),
            resultType: String(reflecting: T.Result.self),
            middleware: middleware,
            callerKey: callerKey
        )
    }
}
