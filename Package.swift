// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExactRestore",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ExactRestore", path: "Sources/ExactRestore")
    ]
)
