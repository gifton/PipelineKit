import Foundation

/// Example demonstrating back-pressure controls in PipelineKit.
///
/// This example shows how to configure and use back-pressure controls
/// to manage command throughput and handle capacity overload scenarios.
public struct BackPressureExample {
    
    /// Demonstrates suspend strategy - producers wait when capacity is exceeded.
    public static func suspendStrategyExample() async throws {
        // Create options with suspend strategy
        let options = PipelineOptions(
            maxConcurrency: 3,
            maxOutstanding: 5,
            backPressureStrategy: .suspend
        )
        
        // Create pipeline with back-pressure control
        let pipeline = ConcurrentPipeline(options: options)
        
        // Register a handler that simulates work
        let handler = SlowCommandHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        await pipeline.register(SlowCommand.self, pipeline: standardPipeline)
        
        print("🔄 Executing commands with suspend strategy...")
        print("📊 Max concurrency: 3, Max outstanding: 5")
        
        // Execute commands - some will suspend when capacity is exceeded
        await withTaskGroup(of: Void.self) { group in
            for i in 1...10 {
                group.addTask {
                    do {
                        let command = SlowCommand(id: i, duration: 2.0)
                        let startTime = Date()
                        
                        let _ = try await pipeline.execute(command) // result
                        let endTime = Date()
                        let waitTime = endTime.timeIntervalSince(startTime) - command.duration
                        
                        print("✅ Command \(i) completed (waited \(String(format: "%.1f", waitTime))s)")
                    } catch {
                        print("❌ Command \(i) failed: \(error)")
                    }
                }
            }
        }
    }
    
    /// Demonstrates drop-oldest strategy - older commands are dropped to make room.
    public static func dropOldestStrategyExample() async throws {
        let options = PipelineOptions(
            maxConcurrency: 2,
            maxOutstanding: 4,
            backPressureStrategy: .dropOldest
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = SlowCommandHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        await pipeline.register(SlowCommand.self, pipeline: standardPipeline)
        
        print("\n🗑️ Executing commands with drop-oldest strategy...")
        print("📊 Max concurrency: 2, Max outstanding: 4")
        
        // Execute commands rapidly - some will be dropped
        await withTaskGroup(of: Void.self) { group in
            for i in 1...8 {
                group.addTask {
                    do {
                        let command = SlowCommand(id: i, duration: 3.0)
                        let _ = try await pipeline.execute(command) // result
                        print("✅ Command \(i) completed successfully")
                    } catch {
                        print("❌ Command \(i) dropped: \(error)")
                    }
                }
                
                // Small delay between submissions to see the effect
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            }
        }
    }
    
    /// Demonstrates error strategy - immediate failure when capacity exceeded.
    public static func errorStrategyExample() async throws {
        let options = PipelineOptions(
            maxConcurrency: 2,
            maxOutstanding: 3,
            backPressureStrategy: .error(timeout: nil)
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = SlowCommandHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        await pipeline.register(SlowCommand.self, pipeline: standardPipeline)
        
        print("\n⚠️ Executing commands with error strategy...")
        print("📊 Max concurrency: 2, Max outstanding: 3")
        
        // Execute commands - excess will fail immediately
        await withTaskGroup(of: Void.self) { group in
            for i in 1...6 {
                group.addTask {
                    do {
                        let command = SlowCommand(id: i, duration: 2.0)
                        let _ = try await pipeline.execute(command) // result
                        print("✅ Command \(i) completed successfully")
                    } catch {
                        print("❌ Command \(i) rejected: \(error)")
                    }
                }
            }
        }
    }
    
    /// Demonstrates back-pressure middleware usage.
    public static func middlewareExample() async throws {
        // Create a standard pipeline
        let handler = SlowCommandHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Add back-pressure middleware
        let backPressureMiddleware = BackPressureMiddleware(
            maxConcurrency: 2,
            maxOutstanding: 4,
            strategy: .suspend
        )
        
        try await pipeline.addMiddleware(backPressureMiddleware)
        
        print("\n🔧 Using BackPressureMiddleware...")
        print("📊 Middleware controls: Max concurrency: 2, Max outstanding: 4")
        
        // Execute commands through middleware
        await withTaskGroup(of: Void.self) { group in
            for i in 1...6 {
                group.addTask {
                    do {
                        let command = SlowCommand(id: i, duration: 1.5)
                        let context = CommandContext(metadata: StandardCommandMetadata())
                        let _ = try await pipeline.execute(command, context: context) // result
                        print("✅ Command \(i) completed through middleware")
                    } catch {
                        print("❌ Command \(i) failed in middleware: \(error)")
                    }
                }
            }
        }
    }
    
    /// Demonstrates capacity monitoring.
    public static func monitoringExample() async throws {
        let options = PipelineOptions(
            maxConcurrency: 3,
            maxOutstanding: 6,
            backPressureStrategy: .suspend
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = SlowCommandHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        await pipeline.register(SlowCommand.self, pipeline: standardPipeline)
        
        print("\n📈 Capacity monitoring example...")
        
        // Start monitoring task
        let monitoringTask = Task {
            while !Task.isCancelled {
                let stats = await pipeline.getCapacityStats()
                print("📊 Active: \(stats.activeOperations), Queued: \(stats.queuedOperations), Utilization: \(String(format: "%.1f", stats.utilizationPercent))%")
                
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
            }
        }
        
        // Execute some commands while monitoring
        await withTaskGroup(of: Void.self) { group in
            for i in 1...8 {
                group.addTask {
                    let command = SlowCommand(id: i, duration: 2.0)
                    let _ = try? await pipeline.execute(command)
                }
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 second between submissions
            }
        }
        
        monitoringTask.cancel()
    }
}

// MARK: - Supporting Types

/// A command that simulates slow processing for demonstration purposes.
private struct SlowCommand: Command {
    typealias Result = String
    
    let id: Int
    let duration: TimeInterval
}

/// A handler that simulates slow processing.
private struct SlowCommandHandler: CommandHandler {
    func handle(_ command: SlowCommand) async throws -> String {
        // Simulate processing time
        try await Task.sleep(nanoseconds: UInt64(command.duration * 1_000_000_000))
        return "Processed command \(command.id)"
    }
}
