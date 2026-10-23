// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BowCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BowCore", targets: ["BowCore"]),
        .library(name: "BowCoreTestSupport", targets: ["BowCoreTestSupport"]),
    ],
    targets: [
        .target(name: "BowCore"),
        // Test doubles, such as the recording engine mock. Linked only by tests, never by the app.
        .target(name: "BowCoreTestSupport", dependencies: ["BowCore"]),
        .testTarget(
            name: "BowCoreTests",
            dependencies: ["BowCore", "BowCoreTestSupport"],
            // Hand written Arc sidebar files for the importer tests.
            resources: [.copy("Fixtures")]),
    ]
)
