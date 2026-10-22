// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BowCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BowCore", targets: ["BowCore"])
    ],
    targets: [
        .target(name: "BowCore"),
        .testTarget(name: "BowCoreTests", dependencies: ["BowCore"]),
    ]
)
