import Foundation
import PipelineKitCore

/// An observer that delegates to multiple child observers
/// Useful for combining different observer behaviors without using ObserverRegistry
public final class CompositeObserver: PipelineObserver {
    private let observers: [PipelineObserver]
    private let errorHandler: @Sendable (Error, String) -> Void
    
    /// Creates a composite observer with multiple child observers
    /// - Parameters:
    ///   - observers: The child observers to delegate to
    ///   - errorHandler: Optional error handler for when child observers fail
    public init(
        observers: [PipelineObserver],
        errorHandler: (@Sendable (Error, String) -> Void)? = nil
    ) {
        self.observers = observers
        self.errorHandler = errorHandler ?? { error, observer in
            print("⚠️ CompositeObserver: \(observer) failed with error: \(error)")
        }
    }
    
    /// Convenience initializer with variadic parameters
    public convenience init(
        _ observers: PipelineObserver...,
        errorHandler: (@Sendable (Error, String) -> Void)? = nil
    ) {
        self.init(observers: observers, errorHandler: errorHandler)
    }
    
    // MARK: - Helper
    
    private func notifyAll(_ operation: (PipelineObserver) async throws -> Void) async {
        for observer in observers {
            do {
                try await operation(observer)
            } catch {
                autoreleasepool {
                    errorHandler(error, String(describing: type(of: observer)))
                }
            }
        }
    }
    
    // MARK: - PipelineObserver Implementation
    
    public func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        await notifyAll { observer in
            await observer.pipelineWillExecute(command, metadata: metadata, pipelineType: pipelineType)
        }
    }
    
    public func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await notifyAll { observer in
            await observer.pipelineDidExecute(command, result: result, metadata: metadata, pipelineType: pipelineType, duration: duration)
        }
    }
    
    public func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await notifyAll { observer in
            await observer.pipelineDidFail(command, error: error, metadata: metadata, pipelineType: pipelineType, duration: duration)
        }
    }
    
    public func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
        await notifyAll { observer in
            await observer.middlewareWillExecute(middlewareName, order: order, correlationId: correlationId)
        }
    }
    
    public func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        await notifyAll { observer in
            await observer.middlewareDidExecute(middlewareName, order: order, correlationId: correlationId, duration: duration)
        }
    }
    
    public func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        await notifyAll { observer in
            await observer.middlewareDidFail(middlewareName, order: order, correlationId: correlationId, error: error, duration: duration)
        }
    }
    
    public func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
        await notifyAll { observer in
            await observer.handlerWillExecute(command, handlerType: handlerType, correlationId: correlationId)
        }
    }
    
    public func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
        await notifyAll { observer in
            await observer.handlerDidExecute(command, result: result, handlerType: handlerType, correlationId: correlationId, duration: duration)
        }
    }
    
    public func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
        await notifyAll { observer in
            await observer.handlerDidFail(command, error: error, handlerType: handlerType, correlationId: correlationId, duration: duration)
        }
    }
    
    public func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        await notifyAll { observer in
            await observer.customEvent(eventName, properties: properties, correlationId: correlationId)
        }
    }
}

// MARK: - Conditional Observer

/// An observer that conditionally forwards events based on a predicate
///
/// ## Design Decision: @unchecked Sendable for Wrapped Protocol Type
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Wrapped Protocol Type**: The stored property `wrapped: PipelineObserver` is a
///    protocol type. While PipelineObserver requires Sendable, Swift cannot currently
///    verify this through existential types.
///
/// 2. **All Properties Are Safe**:
///    - `wrapped`: PipelineObserver protocol requires Sendable
///    - `predicate`: Explicitly marked as @Sendable, ensuring thread safety
///
/// 3. **Type Safety Guarantee**: Since PipelineObserver protocol requires Sendable,
///    any observer passed to this wrapper must be thread-safe by definition.
///
/// 4. **Immutable Design**: Both properties are `let` constants, preventing any
///    modifications after initialization.
///
/// This is a Swift compiler limitation with existential types rather than a design flaw.
public final class ConditionalObserver: PipelineObserver, @unchecked Sendable {
    public typealias Predicate = @Sendable (String, String?) -> Bool // (commandType, correlationId) -> shouldObserve
    
    private let wrapped: PipelineObserver
    private let predicate: Predicate
    
    public init(
        wrapping observer: PipelineObserver,
        when predicate: @escaping Predicate
    ) {
        self.wrapped = observer
        self.predicate = predicate
    }
    
    // Convenience initializers for common conditions
    
    /// Only observe commands of specific types
    public static func forCommands(
        _ commandTypes: String...,
        observer: PipelineObserver
    ) -> ConditionalObserver {
        ConditionalObserver(wrapping: observer) { commandType, _ in
            commandTypes.contains(commandType)
        }
    }
    
    /// Only observe commands matching a pattern
    public static func matching(
        pattern: String,
        observer: PipelineObserver
    ) -> ConditionalObserver {
        ConditionalObserver(wrapping: observer) { commandType, _ in
            commandType.contains(pattern)
        }
    }
    
    /// Only observe failed executions
    public static func onlyFailures(
        observer: PipelineObserver
    ) -> PipelineObserver {
        return FailureOnlyObserver(wrapped: observer)
    }
    
    // MARK: - PipelineObserver Implementation
    
    public func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        guard predicate(String(describing: type(of: command)), metadata.correlationId) else { return }
        await wrapped.pipelineWillExecute(command, metadata: metadata, pipelineType: pipelineType)
    }
    
    public func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        guard predicate(String(describing: type(of: command)), metadata.correlationId) else { return }
        await wrapped.pipelineDidExecute(command, result: result, metadata: metadata, pipelineType: pipelineType, duration: duration)
    }
    
    public func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        guard predicate(String(describing: type(of: command)), metadata.correlationId) else { return }
        await wrapped.pipelineDidFail(command, error: error, metadata: metadata, pipelineType: pipelineType, duration: duration)
    }
    
    // Forward other events based on correlation ID only
    public func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
        guard predicate("", correlationId) else { return }
        await wrapped.middlewareWillExecute(middlewareName, order: order, correlationId: correlationId)
    }
    
    public func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        guard predicate("", correlationId) else { return }
        await wrapped.middlewareDidExecute(middlewareName, order: order, correlationId: correlationId, duration: duration)
    }
    
    public func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        guard predicate("", correlationId) else { return }
        await wrapped.middlewareDidFail(middlewareName, order: order, correlationId: correlationId, error: error, duration: duration)
    }
    
    public func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
        guard predicate(String(describing: type(of: command)), correlationId) else { return }
        await wrapped.handlerWillExecute(command, handlerType: handlerType, correlationId: correlationId)
    }
    
    public func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
        guard predicate(String(describing: type(of: command)), correlationId) else { return }
        await wrapped.handlerDidExecute(command, result: result, handlerType: handlerType, correlationId: correlationId, duration: duration)
    }
    
    public func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
        guard predicate(String(describing: type(of: command)), correlationId) else { return }
        await wrapped.handlerDidFail(command, error: error, handlerType: handlerType, correlationId: correlationId, duration: duration)
    }
    
    public func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        guard predicate("", correlationId) else { return }
        await wrapped.customEvent(eventName, properties: properties, correlationId: correlationId)
    }
}

// MARK: - Specialized Observers

/// An observer that only observes failure events
///
/// ## Design Decision: @unchecked Sendable for Wrapped Protocol Type
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Wrapped Protocol Type**: The stored property `wrapped: PipelineObserver` holds a
///    protocol type. While PipelineObserver requires Sendable, Swift cannot verify this
///    through existential types.
///
/// 2. **Thread Safety Guarantee**: Since PipelineObserver protocol explicitly requires
///    Sendable, any wrapped observer is guaranteed to be thread-safe at compile time.
///
/// 3. **Immutable Reference**: The `wrapped` property is a `let` constant, preventing
///    reassignment after initialization.
///
/// 4. **Private Scope**: As a private class, its usage is controlled and verified within
///    this file, reducing the risk of misuse.
///
/// This is the same Swift limitation seen in other wrapper types - the code is thread-safe
/// but the compiler cannot verify it through the type system.
private final class FailureOnlyObserver: PipelineObserver, @unchecked Sendable {
    private let wrapped: PipelineObserver
    
    init(wrapped: PipelineObserver) {
        self.wrapped = wrapped
    }
    
    // Only forward failure events
    func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await wrapped.pipelineDidFail(command, error: error, metadata: metadata, pipelineType: pipelineType, duration: duration)
    }
    
    func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        await wrapped.middlewareDidFail(middlewareName, order: order, correlationId: correlationId, error: error, duration: duration)
    }
    
    func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
        await wrapped.handlerDidFail(command, error: error, handlerType: handlerType, correlationId: correlationId, duration: duration)
    }
}
