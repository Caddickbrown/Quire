// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wander",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Models, parsing and every file operation, in its own package so the
        // iOS project can depend on it from a path that isn't its own folder.
        .package(path: "Core")
    ],
    targets: [
        // The macOS app. Built into a bundle by ./build.sh.
        .executableTarget(
            name: "Wander",
            dependencies: [.product(name: "WanderCore", package: "Core")],
            path: "Sources/Wander"
        ),
        .testTarget(
            name: "WanderCoreTests",
            dependencies: [.product(name: "WanderCore", package: "Core")],
            path: "Tests/WanderCoreTests"
        )
    ]
)
