// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DepthAnything",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DepthAnything", path: "Sources"),
    ]
)
