// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wander",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Models, parsing and every file operation. It sits in its own
        // directory because Xcode's UI cannot resolve a local package whose
        // path is the project's own folder — and the directory name matches the
        // package name, because SwiftPM identifies a path dependency by it.
        .package(path: "WanderCore")
    ],
    targets: [
        // The macOS app. Built into a bundle by ./build.sh.
        .executableTarget(
            name: "Wander",
            dependencies: [.product(name: "WanderCore", package: "WanderCore")],
            path: "Sources/Wander"
        ),
        .testTarget(
            name: "WanderCoreTests",
            dependencies: [.product(name: "WanderCore", package: "WanderCore")],
            path: "Tests/WanderCoreTests"
        )
    ]
)
