// swift-tools-version: 6.0
import PackageDescription

// Bow's engine on system WebKit: the only code in the repository that imports WebKit, with every private WebKit
// name in WebKitSPI.swift (make guards checks both). The app links it from W2.9; until then its tests run in
// `make test` against real WKWebViews in off screen windows of the test process.
let package = Package(
    name: "BowWebKit",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "BowWebKit", targets: ["BowWebKit"])
    ],
    dependencies: [
        .package(path: "../BowCore")
    ],
    targets: [
        .target(
            name: "BowWebKit", dependencies: [.product(name: "BowCore", package: "BowCore")],
            // The scripts tabs add to their pages, read with Bundle.module from the Scripts subdirectory.
            resources: [.copy("Scripts")]),
        .testTarget(
            name: "BowWebKitTests",
            dependencies: ["BowWebKit", .product(name: "BowCore", package: "BowCore")],
            // The pages the loopback fixture server serves, one folder per area.
            resources: [.copy("Fixtures")]),
    ]
)
