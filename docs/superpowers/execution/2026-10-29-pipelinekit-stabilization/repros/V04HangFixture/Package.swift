// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "V04HangFixture",
    platforms: [.macOS(.v26)],
    targets: [.testTarget(name: "HangFixtureTests")]
)
