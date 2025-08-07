import Foundation
#if canImport(Darwin)
import Darwin
#endif
import PipelineKitCore

/// Advanced pipeline execution flow tracer with real-time bottleneck detection.
public actor PipelineFlowTracer {
    // MARK: - Execution Node Representation
    
    public struct ExecutionNode: Sendable, Identifiable, Codable {
        public let id: UUID
        public let name: String
        public let type: NodeType
        public let startTime: Date
        public let endTime: Date?
        public let duration: TimeInterval?
        public let parentId: UUID?
        public let metadata: [String: String] // Simplified for Codable compatibility
        public let status: ExecutionStatus
        
        public enum NodeType: String, Sendable, Codable {
            case command
            case middleware
            case handler
            case context
            case pipeline
        }
        
        public enum ExecutionStatus: String, Sendable, Codable {
            case pending
            case executing
            case completed
            case failed
            case timeout
        }
        
        public init(
            id: UUID = UUID(),
            name: String,
            type: NodeType,
            startTime: Date,
            endTime: Date? = nil,
            parentId: UUID? = nil,
            metadata: [String: String] = [:],
            status: ExecutionStatus = .pending
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.startTime = startTime
            self.endTime = endTime
            self.duration = endTime.map { $0.timeIntervalSince(startTime) }
            self.parentId = parentId
            self.metadata = metadata
            self.status = status
        }
    }
    
    // MARK: - Execution Flow Graph
    
    public struct ExecutionFlow: Sendable, Codable {
        public let id: UUID
        public let commandName: String
        public let startTime: Date
        public let endTime: Date?
        public let nodes: [ExecutionNode]
        public let edges: [ExecutionEdge]
        public let metrics: FlowMetrics
        
        public var totalDuration: TimeInterval? {
            endTime?.timeIntervalSince(startTime)
        }
        
        public var criticalPath: [ExecutionNode] {
            // Calculate the longest execution path
            var visited: Set<UUID> = []
            var longestPath: [ExecutionNode] = []
            
            func dfs(_ nodeId: UUID, path: [ExecutionNode]) {
                guard !visited.contains(nodeId),
                      let node = nodes.first(where: { $0.id == nodeId }) else { return }
                
                visited.insert(nodeId)
                let newPath = path + [node]
                
                let children = edges.filter { $0.from == nodeId }
                if children.isEmpty {
                    if newPath.count > longestPath.count {
                        longestPath = newPath
                    }
                } else {
                    for edge in children {
                        dfs(edge.to, path: newPath)
                    }
                }
            }
            
            if let rootNode = nodes.first(where: { $0.parentId == nil }) {
                dfs(rootNode.id, path: [])
            }
            
            return longestPath
        }
    }
    
    public struct ExecutionEdge: Sendable, Identifiable, Codable {
        public let id: UUID
        public let from: UUID
        public let to: UUID
        public let type: EdgeType
        public let latency: TimeInterval?
        
        public enum EdgeType: String, Sendable, Codable {
            case sequential
            case conditional
            case parallel
            case error
            case timeout
        }
        
        public init(from: UUID, to: UUID, type: EdgeType, latency: TimeInterval? = nil) {
            self.id = UUID()
            self.from = from
            self.to = to
            self.type = type
            self.latency = latency
        }
    }
    
    // MARK: - Performance Metrics
    
    public struct FlowMetrics: Sendable, Codable {
        public let totalExecutionTime: TimeInterval
        public let middlewareTime: TimeInterval
        public let handlerTime: TimeInterval
        public let contextSwitchTime: TimeInterval
        public let memoryPeakUsage: UInt64
        public let bottlenecks: [PerformanceBottleneck]
        public let parallelismLevel: Double
        public let threadUtilization: [String: Double]
        
        public var efficiency: Double {
            // Calculate pipeline efficiency (useful work / total time)
            handlerTime / totalExecutionTime
        }
        
        public var overhead: Double {
            // Calculate middleware overhead
            middlewareTime / totalExecutionTime
        }
    }
    
    public struct PerformanceBottleneck: Sendable, Identifiable, Codable {
        public let id: UUID
        public let nodeId: UUID
        public let type: BottleneckType
        public let severity: Severity
        public let description: String
        public let suggestedFix: String
        public let impact: TimeInterval
        
        public enum BottleneckType: String, Sendable, Codable {
            case slowMiddleware = "slow_middleware"
            case contextContention = "context_contention"
            case memoryPressure = "memory_pressure"
            case backPressure = "back_pressure"
            case sequentialExecution = "sequential_execution"
            case excessiveLogging = "excessive_logging"
        }
        
        public enum Severity: String, Sendable, Comparable, Codable {
            case low
            case medium
            case high
            case critical
            
            public static func < (lhs: Severity, rhs: Severity) -> Bool {
                let order: [Severity] = [.low, .medium, .high, .critical]
                return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
            }
        }
    }
    
    // MARK: - Actor State
    
    private var activeFlows: [UUID: ExecutionFlow] = [:]
    private var completedFlows: [UUID: ExecutionFlow] = [:]
    private var nodeStack: [(UUID, UUID)] = [] // (flowId, nodeId)
    private let maxCompletedFlows: Int
    private let enableRealTimeAnalysis: Bool
    
    public init(maxCompletedFlows: Int = 1000, enableRealTimeAnalysis: Bool = true) {
        self.maxCompletedFlows = maxCompletedFlows
        self.enableRealTimeAnalysis = enableRealTimeAnalysis
    }
    
    // MARK: - Flow Tracking
    
    public func startCommandFlow<T: Command>(_ command: T) -> UUID {
        let flowId = UUID()
        let rootNode = ExecutionNode(
            name: String(describing: T.self),
            type: .command,
            startTime: Date(),
            status: .executing
        )
        
        let flow = ExecutionFlow(
            id: flowId,
            commandName: String(describing: T.self),
            startTime: Date(),
            endTime: nil,
            nodes: [rootNode],
            edges: [],
            metrics: FlowMetrics(
                totalExecutionTime: 0,
                middlewareTime: 0,
                handlerTime: 0,
                contextSwitchTime: 0,
                memoryPeakUsage: 0,
                bottlenecks: [],
                parallelismLevel: 1.0,
                threadUtilization: [:]
            )
        )
        
        activeFlows[flowId] = flow
        nodeStack.append((flowId, rootNode.id))
        
        return flowId
    }
    
    public func startNode(
        flowId: UUID,
        name: String,
        type: ExecutionNode.NodeType,
        metadata: [String: String] = [:]
    ) -> UUID {
        guard let flow = activeFlows[flowId] else { return UUID() }
        
        let parentId = nodeStack.last?.1
        let node = ExecutionNode(
            name: name,
            type: type,
            startTime: Date(),
            parentId: parentId,
            metadata: metadata,
            status: .executing
        )
        
        var updatedNodes = flow.nodes
        updatedNodes.append(node)
        
        var updatedEdges = flow.edges
        if let parentId = parentId {
            updatedEdges.append(ExecutionEdge(
                from: parentId,
                to: node.id,
                type: .sequential
            ))
        }
        
        let updatedFlow = ExecutionFlow(
            id: flow.id,
            commandName: flow.commandName,
            startTime: flow.startTime,
            endTime: flow.endTime,
            nodes: updatedNodes,
            edges: updatedEdges,
            metrics: flow.metrics
        )
        
        activeFlows[flowId] = updatedFlow
        nodeStack.append((flowId, node.id))
        
        return node.id
    }
    
    public func endNode(flowId: UUID, nodeId: UUID, status: ExecutionNode.ExecutionStatus = .completed) {
        guard let flow = activeFlows[flowId] else { return }
        
        let endTime = Date()
        var updatedNodes = flow.nodes
        
        if let index = updatedNodes.firstIndex(where: { $0.id == nodeId }) {
            let node = updatedNodes[index]
            updatedNodes[index] = ExecutionNode(
                id: node.id,
                name: node.name,
                type: node.type,
                startTime: node.startTime,
                endTime: endTime,
                parentId: node.parentId,
                metadata: node.metadata,
                status: status
            )
        }
        
        let updatedFlow = ExecutionFlow(
            id: flow.id,
            commandName: flow.commandName,
            startTime: flow.startTime,
            endTime: flow.endTime,
            nodes: updatedNodes,
            edges: flow.edges,
            metrics: flow.metrics
        )
        
        activeFlows[flowId] = updatedFlow
        
        // Remove from stack
        nodeStack.removeAll { $0.1 == nodeId }
        
        if enableRealTimeAnalysis {
            Task {
                self.analyzeBottlenecks(flowId: flowId)
            }
        }
    }
    
    public func endCommandFlow(flowId: UUID, status: ExecutionNode.ExecutionStatus = .completed) {
        guard let flow = activeFlows[flowId] else { return }
        
        let endTime = Date()
        let metrics = calculateMetrics(for: flow)
        
        let completedFlow = ExecutionFlow(
            id: flow.id,
            commandName: flow.commandName,
            startTime: flow.startTime,
            endTime: endTime,
            nodes: flow.nodes,
            edges: flow.edges,
            metrics: metrics
        )
        
        activeFlows.removeValue(forKey: flowId)
        completedFlows[flowId] = completedFlow
        
        // Maintain size limit
        if completedFlows.count > maxCompletedFlows {
            // Remove the first key (oldest flow)
            if let oldestKey = completedFlows.keys.first {
                completedFlows.removeValue(forKey: oldestKey)
            }
        }
        
        nodeStack.removeAll { $0.0 == flowId }
    }
    
    // MARK: - Analysis
    
    private func calculateMetrics(for flow: ExecutionFlow) -> FlowMetrics {
        let totalTime = flow.endTime?.timeIntervalSince(flow.startTime) ?? 0
        
        let middlewareNodes = flow.nodes.filter { $0.type == .middleware }
        let handlerNodes = flow.nodes.filter { $0.type == .handler }
        
        let middlewareTime = middlewareNodes.compactMap(\.duration).reduce(0, +)
        let handlerTime = handlerNodes.compactMap(\.duration).reduce(0, +)
        
        let bottlenecks = identifyBottlenecks(in: flow)
        
        return FlowMetrics(
            totalExecutionTime: totalTime,
            middlewareTime: middlewareTime,
            handlerTime: handlerTime,
            contextSwitchTime: totalTime - middlewareTime - handlerTime,
            memoryPeakUsage: getCurrentMemoryUsage(),
            bottlenecks: bottlenecks,
            parallelismLevel: calculateParallelismLevel(flow),
            threadUtilization: [:]
        )
    }
    
    private func identifyBottlenecks(in flow: ExecutionFlow) -> [PerformanceBottleneck] {
        var bottlenecks: [PerformanceBottleneck] = []
        
        // Identify slow middleware
        let avgMiddlewareDuration = flow.nodes
            .filter { $0.type == .middleware }
            .compactMap(\.duration)
            .reduce(0, +) / Double(flow.nodes.filter { $0.type == .middleware }.count)
        
        for node in flow.nodes.filter({ $0.type == .middleware }) {
            if let duration = node.duration, duration > avgMiddlewareDuration * 2 {
                bottlenecks.append(PerformanceBottleneck(
                    id: UUID(),
                    nodeId: node.id,
                    type: .slowMiddleware,
                    severity: duration > avgMiddlewareDuration * 5 ? .critical : .high,
                    description: "Middleware '\(node.name)' is significantly slower than average",
                    suggestedFix: "Consider optimizing '\(node.name)' or moving expensive operations to async background tasks",
                    impact: duration - avgMiddlewareDuration
                ))
            }
        }
        
        return bottlenecks.sorted { $0.severity > $1.severity }
    }
    
    private func calculateParallelismLevel(_ flow: ExecutionFlow) -> Double {
        // Calculate average concurrent execution level based on overlapping node executions
        guard !flow.nodes.isEmpty else { return 1.0 }
        
        // Create time intervals for each node
        let nodeIntervals = flow.nodes.compactMap { node -> (start: Date, end: Date)? in
            guard let endTime = node.endTime else { return nil }
            return (node.startTime, endTime)
        }
        
        guard !nodeIntervals.isEmpty else { return 1.0 }
        
        // Sort intervals by start time
        let sortedIntervals = nodeIntervals.sorted { $0.start < $1.start }
        
        // Calculate maximum concurrent executions at any point in time
        var maxConcurrency = 0
        var currentConcurrency = 0
        var events: [(Date, Int)] = [] // (time, delta) where delta is +1 for start, -1 for end
        
        for interval in sortedIntervals {
            events.append((interval.start, 1))
            events.append((interval.end, -1))
        }
        
        // Sort events by time, with ends before starts for same time
        events.sort { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1 < rhs.1 // End events (-1) before start events (1)
            }
            return lhs.0 < rhs.0
        }
        
        // Process events to find max concurrency
        for event in events {
            currentConcurrency += event.1
            maxConcurrency = max(maxConcurrency, currentConcurrency)
        }
        
        // Calculate average parallelism level
        // This represents the average number of nodes executing concurrently
        let totalDuration = flow.totalDuration ?? 1.0
        let totalNodeTime = nodeIntervals.reduce(0.0) { sum, interval in
            sum + interval.end.timeIntervalSince(interval.start)
        }
        
        // Average parallelism = total node execution time / total flow duration
        let avgParallelism = totalNodeTime / totalDuration
        
        // Return the average, capped by the maximum observed concurrency
        return min(avgParallelism, Double(maxConcurrency))
    }
    
    private func getCurrentMemoryUsage() -> UInt64 {
        #if canImport(Darwin)
        // For Swift 5.10 with strict concurrency, we'll use a simplified approach
        // that avoids direct mach_task_self_ access
        return getApproximateMemoryUsage()
        #else
        return 0
        #endif
    }
    
    #if canImport(Darwin)
    // Alternative memory measurement that avoids mach_task_self_ concurrency issues
    private func getApproximateMemoryUsage() -> UInt64 {
        // For Swift 5.10 with strict concurrency, we'll return 0 for memory tracking
        // This avoids the concurrency issues with mach_task_self_
        // In production, you might want to use a different monitoring approach
        return 0
    }
    #endif
    
    private func analyzeBottlenecks(flowId: UUID) {
        // Real-time bottleneck analysis would go here
        // Could trigger alerts or automatic optimizations
    }
    
    // MARK: - Visualization Data
    
    public func getExecutionFlow(id: UUID) -> ExecutionFlow? {
        return activeFlows[id] ?? completedFlows[id]
    }
    
    public func getAllActiveFlows() -> [ExecutionFlow] {
        return Array(activeFlows.values)
    }
    
    public func getAllCompletedFlows() -> [ExecutionFlow] {
        return Array(completedFlows.values)
    }
    
    public func getSystemHealth() -> SystemHealth {
        let allFlows = Array(activeFlows.values) + Array(completedFlows.values)
        let avgExecutionTime = allFlows.compactMap(\.totalDuration).reduce(0, +) / Double(allFlows.count)
        let totalBottlenecks = allFlows.flatMap(\.metrics.bottlenecks)
        
        return SystemHealth(
            activeFlows: activeFlows.count,
            averageExecutionTime: avgExecutionTime,
            bottleneckCount: totalBottlenecks.count,
            criticalBottlenecks: totalBottlenecks.filter { $0.severity == .critical }.count,
            memoryUsage: getCurrentMemoryUsage(),
            overallHealth: calculateOverallHealth(bottlenecks: totalBottlenecks)
        )
    }
    
    public struct SystemHealth: Sendable {
        public let activeFlows: Int
        public let averageExecutionTime: TimeInterval
        public let bottleneckCount: Int
        public let criticalBottlenecks: Int
        public let memoryUsage: UInt64
        public let overallHealth: HealthStatus
        
        public enum HealthStatus: String, Sendable {
            case excellent
            case good
            case degraded
            case critical
        }
    }
    
    private func calculateOverallHealth(bottlenecks: [PerformanceBottleneck]) -> SystemHealth.HealthStatus {
        let criticalCount = bottlenecks.filter { $0.severity == .critical }.count
        let highCount = bottlenecks.filter { $0.severity == .high }.count
        
        if criticalCount > 0 { return .critical }
        if highCount > 3 { return .degraded }
        if bottlenecks.count > 5 { return .good }
        return .excellent
    }
}
