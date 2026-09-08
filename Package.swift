// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wander",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WanderCore", targets: ["WanderCore"])
    ],
    targets: [
        // Models, parsing and every file operation. Foundation only.
        .target(name: "WanderCore", path: "Sources/WanderCore"),
        // The macOS app. Built into a bundle by ./build.sh.
        .executableTarget(name: "Wander", dependencies: ["WanderCore"], path: "Sources/Wander"),
        .testTarget(name: "WanderCoreTests", dependencies: ["WanderCore"], path: "Tests/WanderCoreTests")
    ]
)
