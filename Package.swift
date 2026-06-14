// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iRelay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iRelay",
            path: "Sources/iRelay"
        )
    ]
)
