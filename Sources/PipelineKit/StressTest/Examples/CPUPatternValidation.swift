import Foundation

/// Example showing all CPU load patterns working correctly
public struct CPUPatternValidation {
    
    public static func validateAllPatterns() async throws {
        print("=== CPU Pattern Validation ===\n")
        
        let safetyMonitor = DefaultSafetyMonitor()
        let orchestrator = StressOrchestrator(safetyMonitor: safetyMonitor)
        
        // Test 1: Constant CPU Load Pattern
        print("1. Testing Constant CPU Load Pattern...")
        let constantScenario = CPULoadScenario(
            pattern: .constant(percentage: 0.3),
            duration: 2.0,
            cores: 2
        )
        let constantId = try await orchestrator.schedule(constantScenario)
        print("   ✓ Scheduled constant load (ID: \(constantId))")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await orchestrator.stop(constantId)
        print("   ✓ Stopped constant load\n")
        
        // Test 2: Sine Wave (Oscillating) Pattern
        print("2. Testing Sine Wave CPU Load Pattern...")
        let sineScenario = CPULoadScenario(
            pattern: .sine(min: 0.2, max: 0.6, period: 3.0),
            duration: 6.0,
            cores: 2
        )
        let sineId = try await orchestrator.schedule(sineScenario)
        print("   ✓ Scheduled sine wave load (ID: \(sineId))")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await orchestrator.stop(sineId)
        print("   ✓ Stopped sine wave load\n")
        
        // Test 3: Burst Pattern
        print("3. Testing Burst CPU Load Pattern...")
        let burstScenario = CPULoadScenario(
            pattern: .burst(peak: 0.7, duration: 0.5, interval: 1.0),
            duration: 5.0,
            cores: 2
        )
        let burstId = try await orchestrator.schedule(burstScenario)
        print("   ✓ Scheduled burst load (ID: \(burstId))")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        await orchestrator.stop(burstId)
        print("   ✓ Stopped burst load\n")
        
        // Test 4: Multiple patterns running concurrently
        print("4. Testing Multiple Concurrent Patterns...")
        let scenarios = [
            CPULoadScenario(pattern: .constant(percentage: 0.2), duration: 5.0, cores: 1),
            CPULoadScenario(pattern: .sine(min: 0.1, max: 0.3, period: 2.0), duration: 5.0, cores: 1),
            CPULoadScenario(pattern: .burst(peak: 0.4, duration: 0.3, interval: 0.7), duration: 5.0, cores: 1)
        ]
        
        var ids: [UUID] = []
        for (index, scenario) in scenarios.enumerated() {
            let id = try await orchestrator.schedule(scenario)
            ids.append(id)
            print("   ✓ Scheduled pattern \(index + 1) (ID: \(id))")
        }
        
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        let status = await orchestrator.currentStatus()
        print("   → Active simulations: \(status.activeSimulations.count)")
        
        await orchestrator.stopAll()
        print("   ✓ Stopped all patterns\n")
        
        // Test 5: CPU patterns in scenarios
        print("5. Testing CPU Patterns in Scenarios...")
        
        // Test BurstLoadScenario with CPU focus
        let burstLoadScenario = await BurstLoadScenario(
            name: "CPU-Focused Burst",
            idleDuration: 1.0,
            spikeDuration: 2.0,
            recoveryDuration: 1.0,
            spikeIntensity: BurstLoadScenario.LoadIntensity(
                cpu: 0.8,
                memory: 0.1,
                concurrency: 10,
                resources: 0.1
            )
        )
        
        let result = try await orchestrator.execute(burstLoadScenario)
        print("   ✓ BurstLoadScenario completed: \(result.status)")
        print("   → Baseline CPU: ~\(Int(result.baselineMetrics.cpuUsage * 100))%")
        print("   → Peak CPU: ~\(Int(result.peakMetrics.cpuUsage * 100))%")
        print("   → Recovery CPU: ~\(Int(result.recoveryMetrics.cpuUsage * 100))%\n")
        
        print("=== All CPU Patterns Validated Successfully ===")
    }
    
    public static func demonstrateCPUSimulator() async throws {
        print("\n=== Direct CPU Simulator Demo ===\n")
        
        let safetyMonitor = DefaultSafetyMonitor()
        let simulator = CPULoadSimulator(safetyMonitor: safetyMonitor)
        
        // Demonstrate different CPU operations
        print("1. Sustained Load (50% for 2 seconds)...")
        try await simulator.applySustainedLoad(percentage: 0.5, cores: 2, duration: 2.0)
        print("   ✓ Completed\n")
        
        print("2. Burst Load (80% bursts)...")
        try await simulator.applyBurstLoad(
            percentage: 0.8,
            cores: 2,
            burstDuration: 0.5,
            idleDuration: 0.5,
            totalDuration: 2.0
        )
        print("   ✓ Completed\n")
        
        print("3. Oscillating Load (20% to 60%)...")
        try await simulator.applyOscillatingLoad(
            minPercentage: 0.2,
            maxPercentage: 0.6,
            period: 2.0,
            cores: 2,
            cycles: 2
        )
        print("   ✓ Completed\n")
        
        print("4. Prime Number Calculation Load...")
        try await simulator.applyPrimeCalculationLoad(
            cores: 2,
            duration: 1.0,
            startingFrom: 1_000_000
        )
        print("   ✓ Completed\n")
        
        print("5. Matrix Operation Load...")
        try await simulator.applyMatrixOperationLoad(
            matrixSize: 256,
            cores: 2,
            duration: 1.0
        )
        print("   ✓ Completed\n")
        
        print("=== CPU Simulator Demo Complete ===")
    }
}