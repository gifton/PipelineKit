import Foundation

/// Protocol for middleware that requires context access
/// This is now just a marker protocol since all middleware use context
@available(*, deprecated, message: "All middleware now support context. Use Middleware protocol directly.")
public protocol ContextAwareMiddleware: Middleware {}