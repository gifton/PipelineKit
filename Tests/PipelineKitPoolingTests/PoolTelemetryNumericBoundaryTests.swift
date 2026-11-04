import Foundation
import XCTest
import PipelineKitPooling

final class PoolTelemetryNumericBoundaryTests: XCTestCase {
    /// The host driver runs each selected boundary in a separate process.
    func testNumericConfigurationProbe() {
        let environment = ProcessInfo.processInfo.environment
        guard let entry = environment["PIPELINEKIT_NUMERIC_ENTRY"],
              let raw = environment["PIPELINEKIT_NUMERIC_VALUE"], let value = Int(raw) else { return }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_REACHED\n".utf8))
        switch entry {
        case "telemetry-pool-series": _ = PoolObservability(maximumSeries: value)
        case "telemetry-pool-window": _ = PoolObservability(distributionWindowSize: value)
        default: XCTFail("Unknown pool telemetry numeric probe \(entry)")
        }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_ACCEPTED\n".utf8))
    }
}
