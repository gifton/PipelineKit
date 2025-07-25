import XCTest
@testable import PipelineKit

final class CommandContextForkTests: XCTestCase {
    
    // MARK: - Test Context Keys
    
    struct StringKey: ContextKey {
        typealias Value = String
    }
    
    struct IntKey: ContextKey {
        typealias Value = Int
    }
    
    struct ArrayKey: ContextKey {
        typealias Value = [String]
    }
    
    struct DictionaryKey: ContextKey {
        typealias Value = [String: Int]
    }
    
    // MARK: - Basic Fork Tests
    
    func testForkCreatesIndependentContext() {
        // Given: A context with some values
        let original = CommandContext()
        original.set("original", for: StringKey.self)
        original.set(42, for: IntKey.self)
        
        // When: We fork the context
        let forked = original.fork()
        
        // Then: The forked context has the same values
        XCTAssertEqual(forked[StringKey.self], "original")
        XCTAssertEqual(forked[IntKey.self], 42)
        
        // And: Changes to the forked context don't affect the original
        forked.set("forked", for: StringKey.self)
        forked.set(100, for: IntKey.self)
        
        XCTAssertEqual(original[StringKey.self], "original")
        XCTAssertEqual(original[IntKey.self], 42)
        XCTAssertEqual(forked[StringKey.self], "forked")
        XCTAssertEqual(forked[IntKey.self], 100)
    }
    
    func testForkWithEmptyContext() {
        // Given: An empty context
        let original = CommandContext()
        
        // When: We fork it
        let forked = original.fork()
        
        // Then: The forked context is also empty
        XCTAssertNil(forked[StringKey.self])
        
        // And: We can add values to the fork without affecting the original
        forked.set("forked", for: StringKey.self)
        
        XCTAssertNil(original[StringKey.self])
        XCTAssertEqual(forked[StringKey.self], "forked")
    }
    
    func testForkPreservesMetadata() {
        // Given: A context with custom metadata
        let metadata = StandardCommandMetadata(
            id: UUID(),
            timestamp: Date(),
            userId: "test-user",
            correlationId: "test-123"
        )
        let original = CommandContext(metadata: metadata)
        
        // When: We fork the context
        let forked = original.fork()
        
        // Then: The metadata is preserved
        XCTAssertEqual(forked.commandMetadata.id, metadata.id)
        XCTAssertEqual(forked.commandMetadata.correlationId, "test-123")
        XCTAssertEqual(forked.commandMetadata.userId, "test-user")
    }
    
    // MARK: - Merge Tests
    
    func testMergeOverwritesValues() {
        // Given: Two contexts with different values
        let context1 = CommandContext()
        context1.set("value1", for: StringKey.self)
        context1.set(1, for: IntKey.self)
        
        let context2 = CommandContext()
        context2.set("value2", for: StringKey.self)
        context2.set(2, for: IntKey.self)
        
        // When: We merge context2 into context1
        context1.merge(from: context2)
        
        // Then: Context1 has values from context2
        XCTAssertEqual(context1[StringKey.self], "value2")
        XCTAssertEqual(context1[IntKey.self], 2)
    }
    
    func testMergeAddsNewValues() {
        // Given: Contexts with non-overlapping keys
        let context1 = CommandContext()
        context1.set("string", for: StringKey.self)
        
        let context2 = CommandContext()
        context2.set(42, for: IntKey.self)
        
        // When: We merge context2 into context1
        context1.merge(from: context2)
        
        // Then: Context1 has values from both
        XCTAssertEqual(context1[StringKey.self], "string")
        XCTAssertEqual(context1[IntKey.self], 42)
    }
    
    func testMergeWithEmptyContext() {
        // Given: A context with values and an empty context
        let context1 = CommandContext()
        context1.set("value", for: StringKey.self)
        
        let emptyContext = CommandContext()
        
        // When: We merge the empty context
        context1.merge(from: emptyContext)
        
        // Then: Original values are preserved
        XCTAssertEqual(context1[StringKey.self], "value")
    }
    
    // MARK: - Snapshot Tests
    
    func testSnapshot() {
        // Given: A context with various values
        let context = CommandContext()
        context.set("test", for: StringKey.self)
        context.set(42, for: IntKey.self)
        context.set(["a", "b", "c"], for: ArrayKey.self)
        
        // When: We create a snapshot
        let snapshot = context.snapshot()
        
        // Then: The snapshot contains all values
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertNotNil(snapshot[StringKey.keyID])
        XCTAssertNotNil(snapshot[IntKey.keyID])
        XCTAssertNotNil(snapshot[ArrayKey.keyID])
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentForkingIsSafe() async {
        // Given: A context with initial values
        let original = CommandContext()
        original.set("initial", for: StringKey.self)
        original.set(0, for: IntKey.self)
        
        // When: Multiple threads fork and modify contexts concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let forked = original.fork()
                    forked.set("fork-\(i)", for: StringKey.self)
                    forked.set(i, for: IntKey.self)
                    
                    // Verify the forked context has the expected values
                    XCTAssertEqual(forked[StringKey.self], "fork-\(i)")
                    XCTAssertEqual(forked[IntKey.self], i)
                }
            }
        }
        
        // Then: The original context is unchanged
        XCTAssertEqual(original[StringKey.self], "initial")
        XCTAssertEqual(original[IntKey.self], 0)
    }
    
    func testConcurrentMergeIsSafe() async {
        // Given: A main context
        let mainContext = CommandContext()
        
        // When: Multiple threads merge their contexts concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let forked = CommandContext()
                    forked.set("value-\(i)", for: StringKey.self)
                    
                    // Small delay to increase contention
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    
                    mainContext.merge(from: forked)
                }
            }
        }
        
        // Then: The main context has one of the merged values (last write wins)
        XCTAssertNotNil(mainContext[StringKey.self])
        XCTAssertTrue(mainContext[StringKey.self]?.starts(with: "value-") ?? false)
    }
    
    // MARK: - Reference Type Tests
    
    func testForkWithReferenceTypes() {
        // Given: A context with a reference type (array)
        let original = CommandContext()
        let originalArray = ["a", "b", "c"]
        original.set(originalArray, for: ArrayKey.self)
        
        // When: We fork and modify the array in the fork
        let forked = original.fork()
        var forkedArray = forked[ArrayKey.self] ?? []
        forkedArray.append("d")
        forked.set(forkedArray, for: ArrayKey.self)
        
        // Then: The original array is unchanged (shallow copy behavior)
        XCTAssertEqual(original[ArrayKey.self], ["a", "b", "c"])
        XCTAssertEqual(forked[ArrayKey.self], ["a", "b", "c", "d"])
    }
    
    // MARK: - Complex Scenario Tests
    
    func testForkMergeCycle() {
        // Given: An original context
        let original = CommandContext()
        original.set("original", for: StringKey.self)
        original.set(1, for: IntKey.self)
        
        // When: We fork, modify, and merge back
        let fork1 = original.fork()
        fork1.set("fork1", for: StringKey.self)
        fork1.set(2, for: IntKey.self)
        
        let fork2 = original.fork()
        fork2.set("fork2", for: StringKey.self)
        fork2.set(3, for: IntKey.self)
        
        // Merge both forks back to original
        original.merge(from: fork1)
        original.merge(from: fork2)
        
        // Then: Original has the last merged values
        XCTAssertEqual(original[StringKey.self], "fork2")
        XCTAssertEqual(original[IntKey.self], 3)
    }
}