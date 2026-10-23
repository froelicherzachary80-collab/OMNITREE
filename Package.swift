// swift-tools-version:5.9
// Multiverse Tree — core engine package.
// The core (graph database, pathfinding, genealogy, research connectors and the
// Multiverse Intelligence Engine) is platform-independent so it can be unit-tested
// on Linux CI as well as macOS. The iOS app target (App/) links this package.
import PackageDescription

let package = Package(
    name: "MultiverseCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MultiverseCore", targets: ["MultiverseCore"]),
        .executable(name: "mvt", targets: ["mvt"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "MultiverseCore",
            dependencies: ["CSQLite"],
            path: "Sources/MultiverseCore"
        ),
        .executableTarget(
            name: "mvt",
            dependencies: ["MultiverseCore"],
            path: "Sources/mvt"
        ),
        .testTarget(
            name: "MultiverseCoreTests",
            dependencies: ["MultiverseCore"],
            path: "Tests/MultiverseCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
