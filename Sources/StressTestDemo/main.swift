import Foundation
import PipelineKit

// Simple demonstration of the Memory Pressure Simulator
@main
struct StressTestDemo {
    static func main() async {
        print("=== PipelineKit Stress Test Demo ===\n")
        
        let orchestrator = StressOrchestrator()
        
        // Demo 1: Basic Memory Allocation
        print("Demo 1: Basic Memory Allocation")
        print("-------------------------------")
        
        do {
            let scenario = BasicMemoryScenario(
                name: "Demo Memory Test",
                timeout: 30,
                configuration: .init(
                    targetUsage: 0.05,  // 5% of system memory
                    rampUpDuration: 3.0,
                    holdDuration: 2.0,
                    createFragmentation: false
                )
            )
            
            print("Running memory pressure test...")
            print("Target: 5% of system memory")
            print("Ramp up: 3 seconds")
            print("Hold: 2 seconds\n")
            
            let result = try await orchestrator.execute(scenario)
            
            print("Result: \(result.status)")
            print("Baseline memory: \(result.baselineMetrics.memoryUsage / 1_000_000)MB")
            print("Peak memory: \(result.peakMetrics.memoryUsage / 1_000_000)MB")
            print("Recovery memory: \(result.recoveryMetrics.memoryUsage / 1_000_000)MB")
            
            if !result.warnings.isEmpty {
                print("\nWarnings:")
                for warning in result.warnings {
                    print("  - [\(warning.level)] \(warning.message)")
                }
            }
        } catch {
            print("Test failed: \(error)")
        }
        
        print("\n")
        
        // Demo 2: Memory Burst Test
        print("Demo 2: Memory Burst Test")
        print("-------------------------")
        
        do {
            let burstScenario = MemoryBurstScenario(
                configuration: .init(
                    burstSize: 20_000_000,  // 20MB bursts
                    burstCount: 3,
                    holdTime: 1.0,
                    burstDelay: 0.5
                )
            )
            
            print("Running burst test...")
            print("Burst size: 20MB")
            print("Burst count: 3")
            print("Hold each burst: 1 second\n")
            
            let result = try await orchestrator.execute(burstScenario)
            print("Result: \(result.status)")
            
        } catch {
            print("Burst test failed: \(error)")
        }
        
        print("\n")
        
        // Demo 3: CPU Load Test
        print("Demo 3: CPU Load Test")
        print("---------------------")
        
        do {
            let cpuScenario = BasicCPUScenario(
                configuration: .init(
                    targetUsage: 0.5,  // 50% CPU
                    cores: 2,          // Use 2 cores
                    duration: 5.0,     // 5 seconds
                    includePrimeCalc: true
                )
            )
            
            print("Running CPU load test...")
            print("Target: 50% CPU on 2 cores")
            print("Duration: 5 seconds\n")
            
            let result = try await orchestrator.execute(cpuScenario)
            print("Result: \(result.status)")
            
        } catch {
            print("CPU test failed: \(error)")
        }
        
        print("\n")
        
        // Demo 4: CPU Burst Pattern
        print("Demo 4: CPU Burst Pattern")
        print("-------------------------")
        
        do {
            let burstScenario = CPUBurstScenario(
                configuration: .init(
                    burstIntensity: 0.8,
                    burstDuration: 1.0,
                    idleDuration: 2.0,
                    totalDuration: 10.0,
                    cores: 2
                )
            )
            
            print("Running CPU burst test...")
            print("Burst: 80% for 1s, idle for 2s")
            print("Total duration: 10 seconds\n")
            
            let result = try await orchestrator.execute(burstScenario)
            print("Result: \(result.status)")
            
        } catch {
            print("CPU burst test failed: \(error)")
        }
        
        // Shutdown
        await orchestrator.shutdown()
        print("\nDemo complete!")
    }
}