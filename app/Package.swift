// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LowerThirds",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LowerThirds", targets: ["LowerThirds"]),
        .executable(name: "lt-render", targets: ["lt-render"]),
    ],
    dependencies: [
        .package(path: "Vendor/Syphon"),
    ],
    targets: [
        // Platform-neutral core: state, recent titles, rendering, control server.
        .target(
            name: "LowerThirdsCore",
            path: "Sources/LowerThirdsCore",
            resources: [.copy("Resources/plus-layer.png"), .copy("Resources/gradient-layer.png")]
        ),
        // The menu-bar app: Syphon output + operator window.
        .executableTarget(
            name: "LowerThirds",
            dependencies: ["LowerThirdsCore", .product(name: "Syphon", package: "Syphon")],
            path: "Sources/LowerThirds"
        ),
        // CLI: render stills to PNG and run self-tests (no GUI needed).
        .executableTarget(
            name: "lt-render",
            dependencies: ["LowerThirdsCore"],
            path: "Sources/lt-render"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
