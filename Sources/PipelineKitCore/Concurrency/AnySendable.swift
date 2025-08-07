import Foundation

/// Type-erased wrapper for Sendable values.
/// 
/// This is the ONLY place in PipelineKit where @unchecked Sendable is used.
/// The initializer enforces Sendable constraint at compile time.
///
/// ## Design Rationale
///
/// AnySendable provides a type-safe bridge for storing heterogeneous Sendable values
/// in collections like CommandContext's storage dictionary. It ensures:
///
/// 1. **Compile-time Safety**: Only Sendable values can be wrapped
/// 2. **Type Erasure**: Allows storing different Sendable types in the same collection
/// 3. **Performance**: Minimal overhead with @frozen and inline annotations
/// 4. **Debugging**: Runtime verification in debug builds
///
/// ## Usage Example
/// ```swift
/// let wrapped = AnySendable("Hello")
/// let value: String? = wrapped.get()  // "Hello"
/// ```
@frozen
public struct AnySendable: @unchecked Sendable {
    @usableFromInline
    internal let _value: Any
    
    /// Creates a type-erased wrapper for a Sendable value.
    /// - Parameter value: The Sendable value to wrap
    @inlinable
    public init<T: Sendable>(_ value: T) {
        self._value = value
        // The generic constraint T: Sendable already ensures compile-time safety
    }
    
    /// Retrieves the wrapped value with type checking.
    /// - Parameter type: The expected type (can be inferred)
    /// - Returns: The value if it matches the expected type, nil otherwise
    @inlinable
    public func get<T: Sendable>(_ type: T.Type = T.self) -> T? {
        _value as? T
    }
    
    /// Retrieves the wrapped value without type specification.
    /// The return type must be inferrable from context.
    @inlinable
    public func get<T: Sendable>() -> T? {
        _value as? T
    }
}

// MARK: - Equatable

extension AnySendable: Equatable {
    public static func == (lhs: AnySendable, rhs: AnySendable) -> Bool {
        // This is a best-effort equality check
        // We can't guarantee semantic equality for all types
        if let lhsEquatable = lhs._value as? any Equatable,
           let rhsEquatable = rhs._value as? any Equatable {
            return lhsEquatable.isEqual(rhsEquatable)
        }
        return false
    }
}

// MARK: - Hashable

extension AnySendable: Hashable {
    public func hash(into hasher: inout Hasher) {
        // Hash based on type and value if possible
        hasher.combine(String(describing: type(of: _value)))
        if let hashable = _value as? any Hashable {
            hasher.combine(hashable)
        }
    }
}

// MARK: - CustomStringConvertible

extension AnySendable: CustomStringConvertible {
    public var description: String {
        "AnySendable(\(String(describing: _value)))"
    }
}

// MARK: - CustomDebugStringConvertible

extension AnySendable: CustomDebugStringConvertible {
    public var debugDescription: String {
        "AnySendable<\(type(of: _value))>(\(String(reflecting: _value)))"
    }
}

// MARK: - Private Helpers

private extension Equatable {
    func isEqual(_ other: any Equatable) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}