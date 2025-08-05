import Foundation

// MARK: - Context Extension for Forking

extension CommandContext {
    /// Creates a fork of this context for parallel execution
    /// Each parallel middleware gets its own context to avoid conflicts
    public func fork() -> CommandContext {
        // Create a new context with the same metadata
        let forkedContext = CommandContext(metadata: self.commandMetadata)
        
        // Deep copy all context values to ensure isolation
        lock.lock()
        defer { lock.unlock() }
        
        // Copy all storage entries to the forked context
        for (key, value) in storage {
            // We need to copy the value to ensure isolation
            // For now, we'll do a shallow copy, but this could be enhanced
            // to support deep copying for complex types
            forkedContext.storage[key] = value
        }
        
        return forkedContext
    }
    
    /// Merges changes from a forked context back into this context
    /// Used when parallel middleware needs to propagate changes back
    public func merge(from forkedContext: CommandContext) {
        lock.lock()
        defer { lock.unlock() }
        
        forkedContext.lock.lock()
        defer { forkedContext.lock.unlock() }
        
        // Merge all values from the forked context
        // This is a simple overwrite strategy - more sophisticated
        // merge strategies could be implemented based on needs
        for (key, value) in forkedContext.storage {
            storage[key] = value
        }
    }
    
    /// Resets the context with new metadata
    internal func reset(with metadata: CommandMetadata) {
        lock.lock()
        defer { lock.unlock() }
        
        // Clear existing storage
        storage.removeAll(keepingCapacity: true)
        
        // Update metadata
        self.metadata = metadata
    }
}
