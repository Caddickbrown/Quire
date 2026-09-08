// swift-tools-version:5.9
import PackageDescription

// The shared core lives in its own package directory on purpose: when a local
// package's path is the Xcode project's own folder ("."), Xcode's UI cannot
// resolve the product and reports "Missing package product 'WanderCore'", even
// though the command-line build succeeds. The directory is named for the
// package, since SwiftPM identifies a path dependency by its directory name.
let package = Package(
    name: "WanderCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "WanderCore", targets: ["WanderCore"])
    ],
    targets: [
        .target(name: "WanderCore", path: "Sources/WanderCore")
    ]
)
