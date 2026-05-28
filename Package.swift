// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "gpumon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "gpumon",
            path: "Sources/gpumon"
        )
    ]
)
