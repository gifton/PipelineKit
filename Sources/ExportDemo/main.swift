import Foundation
import PipelineKit

// Demo of the Metric Export System
@main
struct ExportDemo {
    static func main() async {
        print("PipelineKit Metric Export Demo")
        print("==============================\n")
        
        // Create collector
        let collector = MetricCollector(
            configuration: MetricCollector.Configuration(
                collectionInterval: 1.0,
                autoStart: true
            )
        )
        
        await collector.start()
        
        // Demo 1: JSON Export
        print("Demo 1: JSON Export")
        print("-------------------")
        await demoJSONExport(collector)
        print()
        
        // Demo 2: CSV Export  
        print("Demo 2: CSV Export")
        print("------------------")
        await demoCSVExport(collector)
        print()
        
        // Demo 3: Prometheus Export
        print("Demo 3: Prometheus Export")
        print("------------------------")
        await demoPrometheusExport(collector)
        print()
        
        // Demo 4: Multi-Format Export
        print("Demo 4: Multi-Format Export")
        print("---------------------------")
        await demoMultiFormatExport(collector)
        print()
        
        await collector.stop()
    }
    
    static func demoJSONExport(_ collector: MetricCollector) async {
        // Configure JSON exporter
        let jsonConfig = JSONExportConfiguration(
            fileConfig: FileExportConfiguration(
                path: "/tmp/metrics.json",
                maxFileSize: 10_000_000,
                bufferSize: 100,
                flushInterval: 5.0
            ),
            prettyPrint: true,
            dateFormat: .iso8601
        )
        
        do {
            let jsonExporter = try await JSONExporter(configuration: jsonConfig)
            await collector.addExporter(jsonExporter, name: "json")
            
            print("Exporting metrics to JSON...")
            
            // Generate some metrics
            for i in 0..<10 {
                await collector.record(.gauge("temperature.celsius", value: 20.0 + Double(i)))
                await collector.record(.counter("events.processed", value: Double(i * 100)))
                await collector.record(.histogram("response.ms", value: 50.0 + Double.random(in: -20...20)))
                
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
            
            // Force flush
            try await jsonExporter.flush()
            
            print("JSON export completed. Check /tmp/metrics.json")
            
            // Show a sample of the output
            if let content = try? String(contentsOfFile: "/tmp/metrics.json").prefix(500) {
                print("\nSample JSON output:")
                print(content)
                print("...")
            }
            
        } catch {
            print("JSON export failed: \(error)")
        }
    }
    
    static func demoCSVExport(_ collector: MetricCollector) async {
        // Configure CSV exporter
        let csvConfig = CSVExportConfiguration(
            fileConfig: FileExportConfiguration(
                path: "/tmp/metrics.csv",
                bufferSize: 50,
                flushInterval: 2.0
            ),
            separator: ",",
            includeHeaders: true
        )
        
        do {
            let csvExporter = try await CSVExporter(configuration: csvConfig)
            await collector.addExporter(csvExporter, name: "csv")
            
            print("Exporting metrics to CSV...")
            
            // Generate metrics with tags
            for i in 0..<5 {
                await collector.record(
                    MetricDataPoint(
                        timestamp: Date(),
                        name: "cpu.usage",
                        value: 50.0 + Double(i * 5),
                        type: .gauge,
                        tags: ["host": "server\(i)", "region": i < 3 ? "us-east" : "us-west"]
                    )
                )
            }
            
            // Force flush
            try await csvExporter.flush()
            
            print("CSV export completed. Check /tmp/metrics.csv")
            
            // Show the CSV content
            if let content = try? String(contentsOfFile: "/tmp/metrics.csv") {
                print("\nCSV output:")
                print(content)
            }
            
        } catch {
            print("CSV export failed: \(error)")
        }
    }
    
    static func demoPrometheusExport(_ collector: MetricCollector) async {
        // Configure Prometheus exporter
        let promConfig = PrometheusExportConfiguration(
            port: 9091,
            metricsPath: "/metrics",
            globalLabels: ["service": "pipelinekit-demo"],
            prefix: "pipelinekit_"
        )
        
        do {
            let promExporter = try await PrometheusExporter(configuration: promConfig)
            await collector.addExporter(promExporter, name: "prometheus")
            
            print("Prometheus exporter started on http://localhost:9091/metrics")
            print("Generating metrics for Prometheus...")
            
            // Generate various metric types
            for i in 0..<5 {
                // Gauge
                await collector.record(.gauge("memory.usage.bytes", value: 1000000.0 + Double(i * 100000)))
                
                // Counter (monotonic)
                await collector.record(.counter("http.requests.total", value: Double(i * 10)))
                
                // Histogram
                for _ in 0..<10 {
                    await collector.record(.histogram("http.request.duration", value: Double.random(in: 0.01...2.0)))
                }
                
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            }
            
            print("\nSample Prometheus output:")
            print("# HELP pipelinekit_memory_usage_bytes Gauge metric memory.usage.bytes")
            print("# TYPE pipelinekit_memory_usage_bytes gauge")
            print("pipelinekit_memory_usage_bytes{service=\"pipelinekit-demo\"} 1400000")
            print("")
            print("# HELP pipelinekit_http_requests_total Counter metric http.requests.total")
            print("# TYPE pipelinekit_http_requests_total counter")
            print("pipelinekit_http_requests_total{service=\"pipelinekit-demo\"} 40")
            print("")
            print("# HELP pipelinekit_http_request_duration Histogram metric http.request.duration")
            print("# TYPE pipelinekit_http_request_duration histogram")
            print("pipelinekit_http_request_duration_bucket{le=\"0.1\",service=\"pipelinekit-demo\"} 12")
            print("pipelinekit_http_request_duration_bucket{le=\"0.5\",service=\"pipelinekit-demo\"} 28")
            print("pipelinekit_http_request_duration_bucket{le=\"1.0\",service=\"pipelinekit-demo\"} 37")
            print("...")
            
        } catch {
            print("Prometheus export failed: \(error)")
        }
    }
    
    static func demoMultiFormatExport(_ collector: MetricCollector) async {
        print("Setting up multiple exporters simultaneously...")
        
        // Setup all three exporters
        let jsonConfig = JSONExportConfiguration(
            fileConfig: FileExportConfiguration(
                path: "/tmp/multi-metrics.json",
                realTimeExport: true
            ),
            prettyPrint: false
        )
        
        let csvConfig = CSVExportConfiguration(
            fileConfig: FileExportConfiguration(
                path: "/tmp/multi-metrics.csv",
                realTimeExport: true
            )
        )
        
        do {
            let jsonExporter = try await JSONExporter(configuration: jsonConfig)
            let csvExporter = try await CSVExporter(configuration: csvConfig)
            
            await collector.addExporter(jsonExporter, name: "json-multi")
            await collector.addExporter(csvExporter, name: "csv-multi")
            
            print("Generating metrics exported to multiple formats...")
            
            // Simulate a workload
            for i in 0..<20 {
                let timestamp = Date()
                
                // System metrics
                await collector.record(
                    MetricDataPoint(
                        timestamp: timestamp,
                        name: "system.load.1min",
                        value: 2.5 + sin(Double(i) * 0.3),
                        type: .gauge,
                        tags: ["host": "prod-01"]
                    )
                )
                
                // Application metrics
                await collector.record(
                    MetricDataPoint(
                        timestamp: timestamp,
                        name: "app.requests.count",
                        value: Double(i * 50),
                        type: .counter,
                        tags: ["endpoint": "/api/v1/users", "status": "200"]
                    )
                )
                
                // Performance metrics
                let latency = 25.0 + Double.random(in: -10...30)
                await collector.record(
                    MetricDataPoint(
                        timestamp: timestamp,
                        name: "app.latency.ms",
                        value: latency,
                        type: .histogram,
                        tags: ["percentile": "p99"]
                    )
                )
                
                if i % 5 == 0 {
                    print("  Generated \(i + 1) metric samples...")
                }
                
                try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
            }
            
            // Ensure all data is written
            try await jsonExporter.flush()
            try await csvExporter.flush()
            
            print("\nMulti-format export completed!")
            print("Files created:")
            print("  - /tmp/multi-metrics.json")
            print("  - /tmp/multi-metrics.csv")
            
            // Show file sizes
            let jsonSize = try FileManager.default.attributesOfItem(atPath: "/tmp/multi-metrics.json")[.size] as? Int ?? 0
            let csvSize = try FileManager.default.attributesOfItem(atPath: "/tmp/multi-metrics.csv")[.size] as? Int ?? 0
            
            print("\nFile sizes:")
            print("  JSON: \(jsonSize) bytes")
            print("  CSV: \(csvSize) bytes")
            
        } catch {
            print("Multi-format export failed: \(error)")
        }
    }
}