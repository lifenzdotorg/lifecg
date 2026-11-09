// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LifeCG",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LifeCG", targets: ["LifeCG"]),
        .executable(name: "lt-render", targets: ["lt-render"]),
    ],
    dependencies: [
        .package(path: "Vendor/Syphon"),
    ],
    targets: [
        // Platform-neutral core: state, recent titles, rendering, control server.
        .target(
            name: "LifeCGCore",
            path: "Sources/LifeCGCore"
            // Themes are found at app/Themes from the source tree (see Resources.swift).
        ),
        // The menu-bar app: Syphon output + operator window.
        .executableTarget(
            name: "LifeCG",
            dependencies: ["LifeCGCore", .product(name: "Syphon", package: "Syphon")],
            path: "Sources/LifeCG"
        ),
        // CLI: render stills to PNG and run self-tests (no GUI needed).
        .executableTarget(
            name: "lt-render",
            dependencies: ["LifeCGCore"],
            path: "Sources/lt-render"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
