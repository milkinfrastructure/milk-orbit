// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MilkOrbit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "OrbitCore", targets: ["OrbitCore"])],
    targets: [
        .target(name: "OrbitCore", resources: [.process("Resources")]),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"], path: "Tests/OrbitCoreTests", resources: [.process("Fixtures")])
    ]
)
