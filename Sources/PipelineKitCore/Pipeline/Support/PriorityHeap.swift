import Foundation

/// A min-heap implementation optimized for priority queue operations.
/// Provides O(log n) insertion and extraction with support for arbitrary removal.
internal struct PriorityHeap<Element> {
    /// The heap elements stored in array representation
    private var elements: [Element] = []
    
    /// Maps element ID to its current index in the heap
    private var indexMap: [UUID: Int] = [:]
    
    /// Comparator function for heap ordering (returns true if first element has higher priority/lower value)
    private let comparator: (Element, Element) -> Bool
    
    /// Function to extract UUID from element
    private let idExtractor: (Element) -> UUID
    
    /// Callback for index changes during heap operations
    var onIndexChange: ((UUID, Int?) -> Void)?
    
    /// Creates a new priority heap
    /// - Parameters:
    ///   - comparator: Function to compare two elements (returns true if first has higher priority)
    ///   - idExtractor: Function to extract unique ID from element
    init(comparator: @escaping (Element, Element) -> Bool,
         idExtractor: @escaping (Element) -> UUID) {
        self.comparator = comparator
        self.idExtractor = idExtractor
    }
    
    /// The number of elements in the heap
    var count: Int { elements.count }
    
    /// Whether the heap is empty
    var isEmpty: Bool { elements.isEmpty }
    
    /// Inserts a new element into the heap
    /// - Parameter element: The element to insert
    /// - Complexity: O(log n)
    mutating func insert(_ element: Element) {
        let id = idExtractor(element)
        let newIndex = elements.count
        elements.append(element)
        indexMap[id] = newIndex
        onIndexChange?(id, newIndex)
        
        bubbleUp(from: newIndex)
    }
    
    /// Extracts the minimum element (highest priority) from the heap
    /// - Returns: The minimum element, or nil if heap is empty
    /// - Complexity: O(log n)
    mutating func extractMin() -> Element? {
        guard !elements.isEmpty else { return nil }
        
        if elements.count == 1 {
            let element = elements.removeLast()
            let id = idExtractor(element)
            indexMap.removeValue(forKey: id)
            onIndexChange?(id, nil)
            return element
        }
        
        let minElement = elements[0]
        let minId = idExtractor(minElement)
        
        // Move last element to root
        let lastElement = elements.removeLast()
        elements[0] = lastElement
        
        // Update index mappings
        let lastId = idExtractor(lastElement)
        indexMap[lastId] = 0
        indexMap.removeValue(forKey: minId)
        onIndexChange?(lastId, 0)
        onIndexChange?(minId, nil)
        
        // Restore heap property
        bubbleDown(from: 0)
        
        return minElement
    }
    
    /// Removes an element with the given ID
    /// - Parameter id: The ID of the element to remove
    /// - Returns: The removed element, or nil if not found
    /// - Complexity: O(log n)
    mutating func remove(id: UUID) -> Element? {
        guard let index = indexMap[id] else { return nil }
        
        let element = elements[index]
        
        if index == elements.count - 1 {
            // Removing last element
            elements.removeLast()
            indexMap.removeValue(forKey: id)
            onIndexChange?(id, nil)
            return element
        }
        
        // Replace with last element
        let lastElement = elements.removeLast()
        elements[index] = lastElement
        
        // Update mappings
        let lastId = idExtractor(lastElement)
        indexMap[lastId] = index
        indexMap.removeValue(forKey: id)
        onIndexChange?(lastId, index)
        onIndexChange?(id, nil)
        
        // Restore heap property
        // Try bubbling up first, then down if needed
        let parentIndex = parent(of: index)
        if index > 0 && comparator(elements[index], elements[parentIndex]) {
            bubbleUp(from: index)
        } else {
            bubbleDown(from: index)
        }
        
        return element
    }
    
    /// Peeks at the minimum element without removing it
    /// - Returns: The minimum element, or nil if heap is empty
    /// - Complexity: O(1)
    func peek() -> Element? {
        elements.first
    }
    
    /// Returns all elements in an unordered array
    /// - Returns: Array of all elements
    /// - Complexity: O(n)
    func allElements() -> [Element] {
        elements
    }
    
    // MARK: - Private Helper Methods
    
    private func parent(of index: Int) -> Int {
        (index - 1) / 2
    }
    
    private func leftChild(of index: Int) -> Int {
        2 * index + 1
    }
    
    private func rightChild(of index: Int) -> Int {
        2 * index + 2
    }
    
    /// Bubbles an element up to maintain heap property
    private mutating func bubbleUp(from index: Int) {
        var currentIndex = index
        
        while currentIndex > 0 {
            let parentIdx = parent(of: currentIndex)
            
            if comparator(elements[currentIndex], elements[parentIdx]) {
                // Swap with parent
                elements.swapAt(currentIndex, parentIdx)
                
                // Update index mappings
                let currentId = idExtractor(elements[currentIndex])
                let parentId = idExtractor(elements[parentIdx])
                indexMap[currentId] = currentIndex
                indexMap[parentId] = parentIdx
                onIndexChange?(currentId, currentIndex)
                onIndexChange?(parentId, parentIdx)
                
                currentIndex = parentIdx
            } else {
                break
            }
        }
    }
    
    /// Bubbles an element down to maintain heap property
    private mutating func bubbleDown(from index: Int) {
        var currentIndex = index
        
        while true {
            let leftIdx = leftChild(of: currentIndex)
            let rightIdx = rightChild(of: currentIndex)
            var targetIdx = currentIndex
            
            // Find the index with highest priority (minimum value)
            if leftIdx < elements.count && comparator(elements[leftIdx], elements[targetIdx]) {
                targetIdx = leftIdx
            }
            
            if rightIdx < elements.count && comparator(elements[rightIdx], elements[targetIdx]) {
                targetIdx = rightIdx
            }
            
            if targetIdx != currentIndex {
                // Swap with target
                elements.swapAt(currentIndex, targetIdx)
                
                // Update index mappings
                let currentId = idExtractor(elements[currentIndex])
                let targetId = idExtractor(elements[targetIdx])
                indexMap[currentId] = currentIndex
                indexMap[targetId] = targetIdx
                onIndexChange?(currentId, currentIndex)
                onIndexChange?(targetId, targetIdx)
                
                currentIndex = targetIdx
            } else {
                break
            }
        }
    }
}