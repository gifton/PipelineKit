import Foundation

// MARK: - ContextCopyable Extensions

public extension CommandContext {
    /// Creates a new context with deep copies of values that conform to ContextCopyable.
    ///
    /// This method:
    /// 1. Creates a shallow fork of the context
    /// 2. Identifies values that conform to ContextCopyable
    /// 3. Replaces those values with deep copies
    ///
    /// Values that don't conform to ContextCopyable are shallow-copied as normal.
    ///
    /// - Note: This requires values to be accessed through known keys, as
    ///   the snapshot() method returns type-erased values.
    ///
    /// - Parameter copyableKeys: The context keys to check for ContextCopyable conformance
    /// - Returns: A new context with deep-copied values where applicable
    func deepFork<T: Sendable>(copying keys: [ContextKey<T>]) async -> CommandContext {
        let newContext = await self.fork()
        
        for key in keys {
            if let value = self.get(key) as? ContextCopyable,
               let copied = value.contextCopy() as? T {
                await newContext.set(key, value: copied)
            }
        }
        
        return newContext
    }
}
