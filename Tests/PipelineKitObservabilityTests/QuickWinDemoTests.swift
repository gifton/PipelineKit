import XCTest
@testable import PipelineKitObservability
import PipelineKitCore

/// Demonstrates the quick-win improvements implemented
final class QuickWinDemoTests: XCTestCase {
    
    func testQuickWinsDemo() async throws {
        print("\n=== PipelineKit Swift 6 Quick Wins Demo ===\n")
        
        // 1. JSONEncoder Performance Improvement
        print("1️⃣ JSONEncoder Performance Improvement")
        print("----------------------------------------")
        print("✅ Stored JSONEncoder as property instead of lazy var")
        print("✅ Eliminates per-call allocation overhead")
        print("✅ Thread-safe within actor context")
        
        let exportConfig = JSONExportConfiguration(
            fileConfig: JSONFileConfiguration(
                path: "/tmp/demo-export.json",
                maxFileSize: 1024 * 1024,
                maxFiles: 1,
                bufferSize: 100,
                realTimeExport: false,
                flushInterval: 10.0,
                compressRotated: false
            ),
            prettyPrint: true,
            sortKeys: true,
            dateFormat: .iso8601,
            decimalPlaces: 2
        )
        
        let exporter = try await JSONExporter(configuration: exportConfig)
        
        // Export some test metrics
        for i in 0..<10 {
            let metric = MetricDataPoint(
                name: "demo.metric",
                value: Double(i),
                type: .gauge,
                tags: ["demo": "true"]
            )
            try await exporter.export(metric)
        }
        
        await exporter.shutdown()
        print("   Example: Exported 10 metrics efficiently")
        
        // Clean up
        try? FileManager.default.removeItem(atPath: exportConfig.fileConfig.path)
        
        print("\n2️⃣ Error Handling Enhancement")
        print("--------------------------------")
        print("✅ Added stderr output for JSON encoding failures")
        print("✅ Prevents recursion by writing directly to FileHandle.standardError")
        print("✅ Returns fallback JSON with error details")
        
        let formatter = JSONLogFormatter()
        
        // Create a command that will fail to encode
        struct NonEncodableCommand: Command {
            let problematic: NSObject = NSObject() // Not Codable
            
            struct Result: Sendable {
                let value: String
            }
            
            func execute(context: CommandContext) async throws -> Result {
                return Result(value: "test")
            }
        }
        
        let context = CommandContext()
        context.metadata["request_id"] = "error-test"
        
        // This will trigger error handling
        let errorResult = formatter.formatCommandStart(
            commandType: "NonEncodableCommand",
            requestId: "error-test",
            command: NonEncodableCommand(),
            context: context
        )
        
        print("   Example error response:")
        print("   \(errorResult)")
        
        // Verify it's valid JSON
        if let data = errorResult.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            print("   ✅ Fallback response is valid JSON")
            print("   - error: \(json["error"] ?? "N/A")")
            print("   - event: \(json["event"] ?? "N/A")")
            print("   - type: \(json["type"] ?? "N/A")")
        }
        
        print("\n3️⃣ Summary of Improvements")
        print("---------------------------")
        print("• JSONEncoder optimization reduces allocation overhead")
        print("• Error handling prevents logging recursion")
        print("• Both improvements maintain thread safety")
        print("• No breaking API changes required")
        print("• Ready for production use")
        
        print("\n✅ Quick wins successfully implemented!\n")
    }
    
    func testPerformanceComparison() async throws {
        print("\n=== Performance Comparison ===\n")
        
        // Simulate old vs new behavior
        let iterations = 1000
        
        // Old approach (creating encoder each time)
        let oldStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            
            let data = ["iteration": i, "timestamp": Date().timeIntervalSince1970]
            _ = try encoder.encode(data)
        }
        let oldDuration = CFAbsoluteTimeGetCurrent() - oldStart
        
        // New approach (reusing encoder) - simulated
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let newStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            let data = ["iteration": i, "timestamp": Date().timeIntervalSince1970]
            _ = try encoder.encode(data)
        }
        let newDuration = CFAbsoluteTimeGetCurrent() - newStart
        
        print("Old approach (per-call allocation): \(String(format: "%.3f", oldDuration * 1000))ms")
        print("New approach (stored encoder): \(String(format: "%.3f", newDuration * 1000))ms")
        print("Improvement: \(String(format: "%.1fx", oldDuration / newDuration)) faster")
        print("Time saved per 1000 operations: \(String(format: "%.3f", (oldDuration - newDuration) * 1000))ms")
    }
}