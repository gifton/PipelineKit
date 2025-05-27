import Foundation

/// A type-safe result type for command execution.
/// 
/// `CommandResult` represents either a successful command execution with a value
/// or a failure with an error. This provides a functional approach to error handling
/// that's compatible with Swift's concurrency model.
/// 
/// Both `Success` and `Failure` types must be `Sendable` for thread safety.
/// 
/// Example:
/// ```swift
/// func processCommand() -> CommandResult<User, ValidationError> {
///     if isValid {
///         return .success(User(name: "John"))
///     } else {
///         return .failure(ValidationError.invalidInput)
///     }
/// }
/// ```
public enum CommandResult<Success: Sendable, Failure: Error>: Sendable where Failure: Sendable {
    /// A successful result containing a value
    case success(Success)
    
    /// A failed result containing an error
    case failure(Failure)
}

extension CommandResult {
    /// Returns true if this is a success result.
    public var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
    
    /// Returns true if this is a failure result.
    public var isFailure: Bool {
        !isSuccess
    }
    
    /// Transforms a success value using the provided function.
    /// 
    /// If this result is a failure, the transformation is not applied
    /// and the failure is propagated.
    /// 
    /// - Parameter transform: A function that transforms the success value
    /// - Returns: A new result with the transformed value or the original failure
    /// - Throws: Any error thrown by the transform function
    public func map<NewSuccess: Sendable>(
        _ transform: @Sendable (Success) throws -> NewSuccess
    ) rethrows -> CommandResult<NewSuccess, Failure> {
        switch self {
        case .success(let value):
            return .success(try transform(value))
        case .failure(let error):
            return .failure(error)
        }
    }
    
    /// Transforms a success value into a new result using the provided function.
    /// 
    /// This allows chaining operations that might fail. If this result is a failure,
    /// the transformation is not applied and the failure is propagated.
    /// 
    /// - Parameter transform: A function that transforms the success value into a new result
    /// - Returns: The result of the transformation or the original failure
    /// - Throws: Any error thrown by the transform function
    public func flatMap<NewSuccess: Sendable>(
        _ transform: @Sendable (Success) throws -> CommandResult<NewSuccess, Failure>
    ) rethrows -> CommandResult<NewSuccess, Failure> {
        switch self {
        case .success(let value):
            return try transform(value)
        case .failure(let error):
            return .failure(error)
        }
    }
}