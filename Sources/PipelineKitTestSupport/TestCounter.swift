import Foundation

/// Thread-safe counter for test purposes
public actor TestCounter {
    private var value: Int = 0
    private var values: [Int] = []
    
    public init() {}
    
    /// Increment the counter and return the new value
    @discardableResult
    public func increment() -> Int {
        value += 1
        values.append(value)
        return value
    }
    
    /// Decrement the counter and return the new value
    public func decrement() -> Int {
        value -= 1
        return value
    }
    
    /// Get the current value
    public func getValue() -> Int {
        value
    }
    
    /// Get the current value (alias for getValue)
    public func get() -> Int {
        value
    }
    
    /// Set the value
    public func set(_ newValue: Int) {
        value = newValue
        values.append(newValue)
    }
    
    /// Get all recorded values
    public func getValues() -> [Int] {
        values
    }
    
    /// Reset the counter
    public func reset() {
        value = 0
        values.removeAll()
    }
    
    /// Get the maximum value recorded
    public func getMaxValue() -> Int {
        values.max() ?? 0
    }
}

/// Tracks the order of execution for concurrent operations
public actor ExecutionOrderTracker {
    private var order: [String] = []
    private var timestamps: [(String, Date)] = []
    
    public init() {}
    
    /// Record an execution event
    public func recordExecution(_ event: String) {
        order.append(event)
        timestamps.append((event, Date()))
    }
    
    /// Get the execution order
    public func getExecutionOrder() -> [String] {
        order
    }
    
    /// Get the order with timestamps
    public func getTimestamps() -> [(String, Date)] {
        timestamps
    }
    
    /// Check if events occurred in the expected order
    public func verifyOrder(_ expected: [String]) -> Bool {
        order == expected
    }
    
    /// Reset the tracker
    public func reset() {
        order.removeAll()
        timestamps.removeAll()
    }
}
