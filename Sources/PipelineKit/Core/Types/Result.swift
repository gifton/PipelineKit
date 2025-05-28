import Foundation

/// Type alias for Swift's Result type with Sendable constraints.
/// Use this when you need explicit Sendable constraints on both success and failure types.
public typealias SendableResult<Success: Sendable, Failure: Error> = Result<Success, Failure> where Failure: Sendable