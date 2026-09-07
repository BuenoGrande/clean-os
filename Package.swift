// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "clean-os",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CleanOSKit", targets: ["CleanOSKit"]),
        .executable(name: "cleanos", targets: ["cleanos"]),
    ],
    targets: [
        .target(name: "CleanOSKit"),
        .executableTarget(name: "cleanos", dependencies: ["CleanOSKit"]),
        .testTarget(name: "CleanOSKitTests", dependencies: ["CleanOSKit"]),
    ]
)
