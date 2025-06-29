import Foundation

/// Protocol for middleware with explicit priority
@available(*, deprecated, message: "Use Middleware protocol with priority property instead")
public protocol PrioritizedMiddleware: Middleware {}