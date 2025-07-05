import Foundation
import Atomics

/// A work-stealing queue for efficient task distribution
public final class WorkStealingQueue<Element: Sendable>: Sendable {
    private let queues: [WorkerQueue<Element>]
    private let workerCount: Int
    private let nextVictim = ManagedAtomic<Int>(0)
    
    public init(workerCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.workerCount = workerCount
        self.queues = (0..<workerCount).map { _ in WorkerQueue() }
    }
    
    /// Push work to a specific worker's queue
    public func push(_ element: Element, to worker: Int) {
        queues[worker % workerCount].pushBottom(element)
    }
    
    /// Pop work from a worker's own queue
    public func pop(from worker: Int) -> Element? {
        queues[worker % workerCount].popBottom()
    }
    
    /// Steal work from another worker's queue
    public func steal(by worker: Int) -> Element? {
        let startVictim = nextVictim.load(ordering: .relaxed)
        
        for i in 0..<workerCount {
            let victim = (startVictim + i) % workerCount
            if victim == worker { continue } // Don't steal from self
            
            if let stolen = queues[victim].popTop() {
                // Update next victim for better distribution
                nextVictim.store((victim + 1) % workerCount, ordering: .relaxed)
                return stolen
            }
        }
        
        return nil
    }
    
    /// Get approximate total size across all queues
    public var approximateCount: Int {
        queues.reduce(0) { $0 + $1.approximateCount }
    }
}

/// Individual worker queue with work-stealing support
final class WorkerQueue<Element: Sendable>: Sendable {
    // Using a simple array with lock for now
    // In production, consider using a lock-free deque
    private var deque: [Element] = []
    private let lock = NSLock()
    
    /// Push to bottom (owner side)
    func pushBottom(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        deque.append(element)
    }
    
    /// Pop from bottom (owner side)
    func popBottom() -> Element? {
        lock.lock()
        defer { lock.unlock() }
        return deque.popLast()
    }
    
    /// Pop from top (thief side)
    func popTop() -> Element? {
        lock.lock()
        defer { lock.unlock() }
        if !deque.isEmpty {
            return deque.removeFirst()
        }
        return nil
    }
    
    var approximateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deque.count
    }
}

/// Pipeline executor using work-stealing for better load distribution
public actor WorkStealingPipelineExecutor {
    private let workerCount: Int
    private let workQueue: WorkStealingQueue<WorkItem>
    private var workers: [WorkerActor] = []
    
    private struct WorkItem: Sendable {
        let id: UUID
        let execute: @Sendable () async throws -> Any
        let continuation: CheckedContinuation<Any, Error>
    }
    
    public init(workerCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.workerCount = workerCount
        self.workQueue = WorkStealingQueue(workerCount: workerCount)
        
        // Create worker actors
        for i in 0..<workerCount {
            workers.append(WorkerActor(id: i, queue: workQueue))
        }
    }
    
    /// Execute work with work-stealing distribution
    public func execute<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let item = WorkItem(
                id: UUID(),
                execute: { try await work() as Any },
                continuation: continuation
            )
            
            // Hash-based distribution to workers
            let worker = abs(item.id.hashValue) % workerCount
            workQueue.push(item, to: worker)
            
            // Wake up the worker
            Task {
                await workers[worker].processWork()
            }
        } as! T
    }
}

/// Individual worker actor in the work-stealing system
actor WorkerActor {
    let id: Int
    private let queue: WorkStealingQueue<WorkStealingPipelineExecutor.WorkItem>
    private var isProcessing = false
    
    init(id: Int, queue: WorkStealingQueue<WorkStealingPipelineExecutor.WorkItem>) {
        self.id = id
        self.queue = queue
    }
    
    func processWork() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        
        // Process own work first
        while let work = queue.pop(from: id) {
            await executeWork(work)
        }
        
        // Try to steal work
        var steals = 0
        while steals < 3 { // Limit steal attempts
            if let work = queue.steal(by: id) {
                await executeWork(work)
                steals = 0 // Reset on successful steal
            } else {
                steals += 1
            }
        }
    }
    
    private func executeWork(_ work: WorkStealingPipelineExecutor.WorkItem) async {
        do {
            let result = try await work.execute()
            work.continuation.resume(returning: result)
        } catch {
            work.continuation.resume(throwing: error)
        }
    }
}