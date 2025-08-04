import Foundation
import Atomics

/// A token representing an acquired semaphore resource that automatically releases on cleanup.
///
/// `SemaphoreToken` provides safe, automatic resource management for semaphore acquisitions.
/// The token releases its resource when deinitialized, preventing resource leaks even if
/// tasks are cancelled or errors occur.
///
/// ## Design
///
/// This token-based approach solves several critical issues:
/// - **Automatic Cleanup**: Resources are released even if tasks are cancelled
/// - **Prevents Double-Release**: The token tracks its release state atomically
/// - **Task Cancellation Safe**: Works correctly with Swift's cooperative cancellation
/// - **Memory Safe**: No retain cycles or leaked continuations
/// - **Zero-Cost Release**: Uses atomics to avoid actor hops in deinit
///
/// ## Example
/// ```swift
/// let token = try await semaphore.acquire()
/// // Use the resource...
/// // Token automatically releases when it goes out of scope
/// ```
public final class SemaphoreToken: @unchecked Sendable {
    /// Reference to the owning semaphore.
    ///
    /// ## Lifetime Contract
    /// Using unowned(unsafe) for performance - the semaphore MUST outlive all tokens.
    /// Violating this contract will cause undefined behavior (crashes).
    /// 
    /// To ensure safety:
    /// - Store semaphores at application/service level
    /// - Call semaphore.shutdown() before deallocation
    /// - Use debug assertions to catch violations
    ///
    /// If lifetime cannot be guaranteed, consider using weak references instead.
    private unowned(unsafe) let semaphore: BackPressureAsyncSemaphore
    
    /// Unique identifier for this token (using atomic counter for performance).
    internal let id: UInt64
    
    /// Timestamp when this token was acquired.
    private let acquiredAt: Date
    
    /// Atomic flag tracking release state.
    /// 0 = not released, 1 = released
    private let released = ManagedAtomic<UInt8>(0)
    
    /// Whether this token has been released.
    public var isReleased: Bool {
        released.load(ordering: .relaxed) != 0
    }
    
    /// How long this token has held the resource.
    public var holdDuration: TimeInterval {
        Date().timeIntervalSince(acquiredAt)
    }
    
    /// Creates a new semaphore token.
    ///
    /// - Parameters:
    ///   - semaphore: The semaphore that created this token
    ///   - id: Unique identifier for this acquisition
    internal init(semaphore: BackPressureAsyncSemaphore, id: UInt64) {
        self.semaphore = semaphore
        self.id = id
        self.acquiredAt = Date()
    }
    
    /// Explicitly releases the semaphore resource.
    ///
    /// This method is idempotent - calling it multiple times is safe.
    /// The resource is also automatically released when the token is deinitialized.
    public func release() {
        // Atomic compare-and-swap ensures we only release once
        guard released.compareExchange(
            expected: 0,
            desired: 1,
            ordering: .acquiringAndReleasing
        ).exchanged else { return }
        
        // Fast path release - no actor hop needed
        semaphore._fastPathRelease()
    }
    
    /// Ensures the resource is released when the token is deallocated.
    deinit {
        // Fast, non-async release using atomics
        // If CAS fails, someone else already released
        if released.compareExchange(
            expected: 0,
            desired: 1,
            ordering: .acquiringAndReleasing
        ).exchanged {
            semaphore._fastPathRelease()
        }
    }
}

// MARK: - Equatable & Hashable

extension SemaphoreToken: Equatable {
    public static func == (lhs: SemaphoreToken, rhs: SemaphoreToken) -> Bool {
        lhs.id == rhs.id
    }
}

extension SemaphoreToken: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Diagnostic Support

extension SemaphoreToken: CustomStringConvertible {
    public var description: String {
        "SemaphoreToken(id: \(id), held: \(String(format: "%.2f", holdDuration))s)"
    }
}

// MARK: - Release State Actor

/// Actor to manage release state without atomics
private actor ReleaseState {
    private var released = false
    
    var isReleased: Bool {
        released
    }
    
    /// Sets the released state and returns the previous value
    func setReleased() -> Bool {
        let wasReleased = released
        released = true
        return wasReleased
    }
}

