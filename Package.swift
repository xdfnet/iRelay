// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iRelay",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "iRelayCore",
            path: "Sources/iRelayCore"
        ),
        .executableTarget(
            name: "iRelay",
            dependencies: ["iRelayCore"],
            path: "Sources/iRelay"
        ),
        .testTarget(
            name: "iRelayTests",
            dependencies: ["iRelayCore"],
            path: "Tests/iRelayTests"
        ),
    ]
)
