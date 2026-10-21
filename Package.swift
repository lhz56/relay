// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Relay", targets: ["RelayApp"])],
    targets: [
        .target(name: "RelayCore"),
        .executableTarget(name: "RelayApp", dependencies: ["RelayCore"]),
        .executableTarget(name: "RelayChecks", dependencies: ["RelayCore"], path: "Tests/RelayCoreTests")
    ]
)
