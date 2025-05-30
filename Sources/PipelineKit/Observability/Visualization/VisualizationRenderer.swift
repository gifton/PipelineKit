import Foundation

/// Advanced pipeline visualization renderer with multiple output formats.
public struct VisualizationRenderer {
    
    public enum OutputFormat {
        case mermaid
        case graphviz
        case json
        case ascii
        case html
    }
    
    // MARK: - Mermaid Diagram Generation
    
    public static func renderMermaidDiagram(flow: PipelineFlowTracer.ExecutionFlow) -> String {
        var mermaid = """
        graph TD
        classDef command fill:#e1f5fe
        classDef middleware fill:#f3e5f5
        classDef handler fill:#e8f5e8
        classDef error fill:#ffebee
        classDef slow fill:#fff3e0
        
        """
        
        // Add nodes
        for node in flow.nodes {
            let styleClass = getNodeStyleClass(node)
            let duration = node.duration.map { String(format: "%.3fs", $0) } ?? "..."
            let label = "\(node.name)\\n\(duration)"
            mermaid += "    \(node.id.uuidString.prefix(8))[\"\(label)\"]\n"
            mermaid += "    class \(node.id.uuidString.prefix(8)) \(styleClass)\n"
        }
        
        mermaid += "\n"
        
        // Add edges
        for edge in flow.edges {
            let fromId = edge.from.uuidString.prefix(8)
            let toId = edge.to.uuidString.prefix(8)
            let edgeStyle = getEdgeStyle(edge)
            mermaid += "    \(fromId) \(edgeStyle) \(toId)\n"
        }
        
        // Add bottleneck annotations
        for bottleneck in flow.metrics.bottlenecks {
            let nodeId = bottleneck.nodeId.uuidString.prefix(8)
            mermaid += "    \(nodeId) -.-> BOTTLENECK\(bottleneck.id.uuidString.prefix(8))[\"🚨 \(bottleneck.type.rawValue)\"]\n"
            mermaid += "    class BOTTLENECK\(bottleneck.id.uuidString.prefix(8)) error\n"
        }
        
        return mermaid
    }
    
    private static func getNodeStyleClass(_ node: PipelineFlowTracer.ExecutionNode) -> String {
        switch node.status {
        case .failed:
            return "error"
        case .timeout:
            return "error"
        default:
            if let duration = node.duration, duration > 0.1 {
                return "slow"
            }
            
            switch node.type {
            case .command:
                return "command"
            case .middleware:
                return "middleware"
            case .handler:
                return "handler"
            case .context, .pipeline:
                return "middleware"
            }
        }
    }
    
    private static func getEdgeStyle(_ edge: PipelineFlowTracer.ExecutionEdge) -> String {
        switch edge.type {
        case .sequential:
            return "-->"
        case .conditional:
            return "-..->"
        case .parallel:
            return "==>"
        case .error:
            return "-.->|ERROR|"
        case .timeout:
            return "-.->|TIMEOUT|"
        }
    }
    
    // MARK: - GraphViz DOT Generation
    
    public static func renderGraphvizDot(flow: PipelineFlowTracer.ExecutionFlow) -> String {
        var dot = """
        digraph PipelineFlow {
            rankdir=TD;
            node [shape=box, style=rounded];
            
        """
        
        // Add nodes
        for node in flow.nodes {
            let duration = node.duration.map { String(format: "%.3fs", $0) } ?? "..."
            let color = getNodeColor(node)
            let label = "\(node.name)\\n\(duration)"
            
            dot += "    \"\(node.id)\" [label=\"\(label)\", color=\"\(color)\", fillcolor=\"\(color)\", style=\"filled,rounded\"];\n"
        }
        
        dot += "\n"
        
        // Add edges
        for edge in flow.edges {
            let style = getEdgeStyleDot(edge)
            dot += "    \"\(edge.from)\" -> \"\(edge.to)\" [\(style)];\n"
        }
        
        // Add bottleneck subgraph
        if !flow.metrics.bottlenecks.isEmpty {
            dot += "\n    subgraph cluster_bottlenecks {\n"
            dot += "        label=\"Performance Bottlenecks\";\n"
            dot += "        style=dashed;\n"
            dot += "        color=red;\n"
            
            for bottleneck in flow.metrics.bottlenecks {
                dot += "        \"\(bottleneck.nodeId)\" [color=red, style=\"filled,bold\"];\n"
            }
            
            dot += "    }\n"
        }
        
        dot += "}\n"
        return dot
    }
    
    private static func getNodeColor(_ node: PipelineFlowTracer.ExecutionNode) -> String {
        switch node.status {
        case .failed:
            return "red"
        case .timeout:
            return "orange"
        case .executing:
            return "yellow"
        case .completed:
            if let duration = node.duration, duration > 0.1 {
                return "orange"
            }
            return "lightgreen"
        case .pending:
            return "lightgray"
        }
    }
    
    private static func getEdgeStyleDot(_ edge: PipelineFlowTracer.ExecutionEdge) -> String {
        switch edge.type {
        case .sequential:
            return "color=black"
        case .conditional:
            return "color=blue, style=dashed"
        case .parallel:
            return "color=green, style=bold"
        case .error:
            return "color=red, style=dashed"
        case .timeout:
            return "color=orange, style=dashed"
        }
    }
    
    // MARK: - ASCII Art Generation
    
    public static func renderASCII(flow: PipelineFlowTracer.ExecutionFlow) -> String {
        var ascii = """
        ┌──────────────────────────────────────────────────────────────┐
        │                    Pipeline Execution Flow                   │
        ├──────────────────────────────────────────────────────────────┤
        │ Command: \(flow.commandName.padding(toLength: 47, withPad: " ", startingAt: 0)) │
        │ Duration: \(String(format: "%.3fs", flow.totalDuration ?? 0).padding(toLength: 46, withPad: " ", startingAt: 0)) │
        └──────────────────────────────────────────────────────────────┘
        
        """
        
        // Build execution tree
        let rootNodes = flow.nodes.filter { $0.parentId == nil }
        for rootNode in rootNodes {
            ascii += renderNodeASCII(node: rootNode, flow: flow, depth: 0)
        }
        
        // Add performance summary
        ascii += "\n"
        ascii += renderPerformanceSummaryASCII(flow: flow)
        
        return ascii
    }
    
    private static func renderNodeASCII(
        node: PipelineFlowTracer.ExecutionNode,
        flow: PipelineFlowTracer.ExecutionFlow,
        depth: Int
    ) -> String {
        let indent = String(repeating: "  ", count: depth)
        let duration = node.duration.map { String(format: "%.3fs", $0) } ?? "..."
        let status = getStatusEmoji(node.status)
        
        var result = "\(indent)├─ \(status) \(node.name) (\(duration))\n"
        
        // Add children
        let children = flow.nodes.filter { $0.parentId == node.id }
        for child in children {
            result += renderNodeASCII(node: child, flow: flow, depth: depth + 1)
        }
        
        return result
    }
    
    private static func getStatusEmoji(_ status: PipelineFlowTracer.ExecutionNode.ExecutionStatus) -> String {
        switch status {
        case .pending:
            return "⏳"
        case .executing:
            return "⚡"
        case .completed:
            return "✅"
        case .failed:
            return "❌"
        case .timeout:
            return "⏰"
        }
    }
    
    private static func renderPerformanceSummaryASCII(flow: PipelineFlowTracer.ExecutionFlow) -> String {
        let metrics = flow.metrics
        
        return """
        ┌──────────────────────────────────────────────────────────────┐
        │                    Performance Summary                       │
        ├──────────────────────────────────────────────────────────────┤
        │ Total Time:      \(String(format: "%.3fs", metrics.totalExecutionTime).padding(toLength: 39, withPad: " ", startingAt: 0)) │
        │ Middleware Time: \(String(format: "%.3fs", metrics.middlewareTime).padding(toLength: 39, withPad: " ", startingAt: 0)) │
        │ Handler Time:    \(String(format: "%.3fs", metrics.handlerTime).padding(toLength: 39, withPad: " ", startingAt: 0)) │
        │ Efficiency:      \(String(format: "%.1f%%", metrics.efficiency * 100).padding(toLength: 39, withPad: " ", startingAt: 0)) │
        │ Overhead:        \(String(format: "%.1f%%", metrics.overhead * 100).padding(toLength: 39, withPad: " ", startingAt: 0)) │
        │ Bottlenecks:     \(String(metrics.bottlenecks.count).padding(toLength: 39, withPad: " ", startingAt: 0)) │
        └──────────────────────────────────────────────────────────────┘
        """
    }
    
    // MARK: - JSON Export
    
    public static func renderJSON(flow: PipelineFlowTracer.ExecutionFlow) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            let data = try encoder.encode(flow)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"Failed to encode flow: \(error.localizedDescription)\"}"
        }
    }
    
    // MARK: - HTML Interactive Visualization
    
    public static func renderHTML(flow: PipelineFlowTracer.ExecutionFlow) -> String {
        let mermaidDiagram = renderMermaidDiagram(flow: flow)
        let jsonData = renderJSON(flow: flow)
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Pipeline Flow Visualization</title>
            <script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 20px; }
                .container { max-width: 1200px; margin: 0 auto; }
                .metrics { display: flex; gap: 20px; margin: 20px 0; }
                .metric-card { 
                    background: #f5f5f5; 
                    padding: 15px; 
                    border-radius: 8px; 
                    min-width: 150px; 
                }
                .bottleneck { 
                    background: #ffe6e6; 
                    border-left: 4px solid #ff4444; 
                    padding: 10px; 
                    margin: 10px 0; 
                }
                pre { background: #f5f5f5; padding: 15px; border-radius: 8px; overflow-x: auto; }
                .mermaid { text-align: center; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>Pipeline Flow: \(flow.commandName)</h1>
                
                <div class="metrics">
                    <div class="metric-card">
                        <h3>Total Time</h3>
                        <p>\(String(format: "%.3fs", flow.totalDuration ?? 0))</p>
                    </div>
                    <div class="metric-card">
                        <h3>Efficiency</h3>
                        <p>\(String(format: "%.1f%%", flow.metrics.efficiency * 100))</p>
                    </div>
                    <div class="metric-card">
                        <h3>Bottlenecks</h3>
                        <p>\(flow.metrics.bottlenecks.count)</p>
                    </div>
                    <div class="metric-card">
                        <h3>Memory Peak</h3>
                        <p>\(ByteCountFormatter().string(fromByteCount: Int64(flow.metrics.memoryPeakUsage)))</p>
                    </div>
                </div>
                
                <h2>Execution Flow Diagram</h2>
                <div class="mermaid">
                    \(mermaidDiagram)
                </div>
                
                \(flow.metrics.bottlenecks.isEmpty ? "" : renderBottlenecksHTML(flow.metrics.bottlenecks))
                
                <h2>Raw Data</h2>
                <details>
                    <summary>View JSON Data</summary>
                    <pre><code>\(jsonData)</code></pre>
                </details>
            </div>
            
            <script>
                mermaid.initialize({startOnLoad:true});
            </script>
        </body>
        </html>
        """
    }
    
    private static func renderBottlenecksHTML(_ bottlenecks: [PipelineFlowTracer.PerformanceBottleneck]) -> String {
        var html = "<h2>Performance Bottlenecks</h2>\n"
        
        for bottleneck in bottlenecks {
            html += """
            <div class="bottleneck">
                <h4>\(bottleneck.type.rawValue.capitalized) - \(bottleneck.severity.rawValue.capitalized)</h4>
                <p><strong>Description:</strong> \(bottleneck.description)</p>
                <p><strong>Impact:</strong> +\(String(format: "%.3fs", bottleneck.impact))</p>
                <p><strong>Suggested Fix:</strong> \(bottleneck.suggestedFix)</p>
            </div>
            """
        }
        
        return html
    }
}

// MARK: - Codable Extensions
// Note: These extensions are in a separate file to avoid compiler issues with automatic synthesis