import Foundation
import PipelineKitObservability

/// Example demonstrating metric sampling for high-volume scenarios
@main
struct MetricsSamplingExample {
    static func main() async {
        print("PipelineKit Metrics Sampling Example")
        print("====================================\n")
        
        // Example 1: Basic global sampling (10% of all metrics)
        await basicSampling()
        
        // Example 2: Per-type sampling with different rates
        await perTypeSampling()
        
        // Example 3: Critical metrics bypass
        await criticalMetricsBypass()
        
        print("\n✅ Examples complete!")
    }
    
    static func basicSampling() async {
        print("1. Basic Sampling (10% of metrics):")
        print("-----------------------------------")
        
        await Metrics.configure(
            host: "localhost",
            port: 8125,
            sampleRate: 0.1  // Only send 10% of metrics
        )
        
        // Simulate high-volume metrics
        for i in 0..<100 {
            await Metrics.counter("api.requests", value: 1.0, tags: ["endpoint": "/users"])
            
            if i % 10 == 0 {
                print("  Sent \(i) metrics (only ~10% will be transmitted)")
            }
        }
        
        print("  ✓ High-volume metrics sampled at 10%")
        print("  ✓ Counter values automatically scaled up by 10x to maintain accuracy\n")
    }
    
    static func perTypeSampling() async {
        print("2. Per-Type Sampling:")
        print("---------------------")
        
        await Metrics.configure(
            host: "localhost",
            port: 8125,
            sampleRate: 1.0,  // Default: no sampling
            sampleRatesByType: [
                "counter": 0.1,   // Sample counters at 10%
                "timer": 0.5,     // Sample timers at 50%
                "gauge": 1.0      // Never sample gauges (always send)
            ]
        )
        
        // Different metric types
        for i in 0..<20 {
            // High-volume counter (10% sampling)
            await Metrics.counter("requests.count", value: 1.0)
            
            // Medium-volume timer (50% sampling)
            await Metrics.timer("request.duration", duration: 0.001)
            
            // Important gauge (100% - never sampled)
            await Metrics.gauge("memory.usage", value: Double(i * 1024))
        }
        
        print("  ✓ Counters: 10% sampling (high volume)")
        print("  ✓ Timers: 50% sampling (medium volume)")
        print("  ✓ Gauges: No sampling (important metrics)\n")
    }
    
    static func criticalMetricsBypass() async {
        print("3. Critical Metrics Bypass:")
        print("---------------------------")
        
        await Metrics.configure(
            host: "localhost",
            port: 8125,
            sampleRate: 0.01,  // Aggressive sampling: only 1%
            criticalPatterns: ["error", "timeout", "failure", "critical"]
        )
        
        // Mix of normal and critical metrics
        for i in 0..<100 {
            // High-volume normal metric (1% sampling)
            await Metrics.counter("normal.event", value: 1.0)
            
            // Critical metrics (always sent, never sampled)
            if i % 20 == 0 {
                await Metrics.counter("api.error.500", value: 1.0)
                await Metrics.counter("request.timeout", value: 1.0)
                await Metrics.counter("payment.failure", value: 1.0)
                print("  ! Critical metrics at iteration \(i) - always sent")
            }
        }
        
        print("  ✓ Normal metrics: 1% sampling")
        print("  ✓ Error metrics: Always sent (bypass sampling)")
        print("  ✓ Timeout metrics: Always sent (bypass sampling)")
        print("  ✓ Failure metrics: Always sent (bypass sampling)\n")
    }
}

// MARK: - Production Configuration Examples

extension MetricsSamplingExample {
    /// Example configuration for production environments
    static func productionConfigurations() async {
        
        // High-traffic API server
        await Metrics.configure(
            host: "metrics.internal",
            port: 8125,
            prefix: "api_server",
            globalTags: ["env": "production", "region": "us-east-1"],
            sampleRate: 0.1,  // 10% default
            sampleRatesByType: [
                "counter": 0.05,  // 5% for request counters
                "timer": 0.1,     // 10% for latency timers
                "gauge": 1.0,     // 100% for system metrics
                "histogram": 0.2  // 20% for distributions
            ],
            criticalPatterns: [
                "error", "exception", "fatal",
                "timeout", "circuit_breaker",
                "rate_limit", "throttle",
                "security", "auth_failure"
            ]
        )
        
        // Background job processor
        await Metrics.configure(
            host: "metrics.internal",
            port: 8125,
            prefix: "job_processor",
            sampleRate: 0.5,  // 50% for background jobs
            criticalPatterns: ["job_failed", "dead_letter", "retry_exhausted"]
        )
        
        // Real-time service (minimal sampling)
        await Metrics.configure(
            host: "metrics.internal",
            port: 8125,
            prefix: "realtime",
            sampleRate: 0.01,  // 1% for extremely high volume
            sampleRatesByType: [
                "counter": 0.001,  // 0.1% for message counts
                "timer": 0.01,     // 1% for latencies
                "gauge": 0.1       // 10% for connection counts
            ]
        )
    }
}

// MARK: - Sampling Decision Examples

extension MetricsSamplingExample {
    /// Demonstrates how sampling decisions work
    static func samplingScienceExample() {
        print("Understanding Deterministic Sampling:")
        print("------------------------------------")
        
        // Deterministic sampling ensures consistency
        let metricNames = [
            "api.request.count",      // Hash might sample
            "api.response.time",      // Hash might not sample
            "api.error.count",        // Always sampled (critical)
            "db.query.count",         // Hash determines
            "cache.hit.rate"          // Hash determines
        ]
        
        for name in metricNames {
            let hash = name.hashValue
            let threshold = Int(0.1 * Double(Int.max))  // 10% sampling
            let wouldSample = abs(hash) < threshold
            
            print("  \(name):")
            print("    Hash: \(hash)")
            print("    Would sample: \(wouldSample)")
            print("    Reason: \(name.contains("error") ? "Critical pattern" : "Hash-based")")
        }
        
        print("\nKey Benefits:")
        print("  ✓ Same metric always gets same decision")
        print("  ✓ Debugging is predictable")
        print("  ✓ Statistical accuracy maintained")
        print("  ✓ No memory overhead for tracking")
    }
}