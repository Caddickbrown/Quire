// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wander",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wander",
            path: "Sources/Wander"
        )
    ]
)
