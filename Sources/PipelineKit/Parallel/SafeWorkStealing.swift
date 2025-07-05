import Foundation
import Atomics

/// Safe work-stealing implementation using actors
public actor SafeWorkStealingExecutor {
    private let workers: [WorkerActor]
    private let workerCount: Int
    
    public init(workerCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.workerCount = workerCount
        self.workers = (0..<workerCount).map { WorkerActor(id: $0) }
        
        // Connect workers for stealing
        Task {
            for i in 0..<workerCount {
                let stealTargets = (0..<workerCount).filter { $0 != i }.map { workers[$0] }
                await workers[i].setStealTargets(stealTargets)
            }
        }
    }
    
    /// Execute work with automatic load balancing
    public func execute<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Select worker with least load
        let worker = await selectWorker()
        return try await worker.execute(work)
    }
    
    private func selectWorker() async -> WorkerActor {
        // Simple round-robin with load awareness
        var minLoad = Int.max
        var selectedWorker = workers[0]
        
        for worker in workers {
            let load = await worker.currentLoad
            if load < minLoad {
                minLoad = load
                selectedWorker = worker
            }
        }
        
        return selectedWorker
    }
}

/// Individual worker with safe work queue
actor WorkerActor {
    let id: Int
    private var queue: [WorkItem] = []
    private var stealTargets: [WorkerActor] = []
    private var isProcessing = false
    private let loadCounter = ManagedAtomic<Int>(0)
    
    private struct WorkItem {
        let id = UUID()
        let execute: @Sendable () async throws -> Any
        let continuation: CheckedContinuation<Any, Error>
    }
    
    init(id: Int) {
        self.id = id
    }
    
    func setStealTargets(_ targets: [WorkerActor]) {
        self.stealTargets = targets
    }
    
    var currentLoad: Int {
        loadCounter.load(ordering: .relaxed)
    }
    
    func execute<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        loadCounter.wrappingIncrement(ordering: .relaxed)
        defer { loadCounter.wrappingDecrement(ordering: .relaxed) }
        
        return try await withCheckedThrowingContinuation { continuation in
            let item = WorkItem(
                execute: { try await work() as Any },
                continuation: continuation
            )
            
            queue.append(item)
            
            if !isProcessing {
                Task {
                    await processQueue()
                }
            }
        } as! T
    }
    
    private func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        
        while !queue.isEmpty {
            // Process own queue first
            if let item = queue.first {
                queue.removeFirst()
                await executeItem(item)
            }
            
            // Try to steal if queue is empty
            if queue.isEmpty {
                await tryStealWork()
            }
        }
    }
    
    private func tryStealWork() async {
        for target in stealTargets.shuffled() {
            if let stolenItem = await target.stealWork() {
                await executeItem(stolenItem)
                break
            }
        }
    }
    
    private func stealWork() -> WorkItem? {
        guard queue.count > 1 else { return nil }
        // Steal from the back to reduce contention
        return queue.removeLast()
    }
    
    private func executeItem(_ item: WorkItem) async {
        do {
            let result = try await item.execute()
            item.continuation.resume(returning: result)
        } catch {
            item.continuation.resume(throwing: error)
        }
    }
}