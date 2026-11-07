// swift-tools-version:6.0
// Syphon-Framework vendored as a Swift Package buildable with the Command Line Tools only
// (no Xcode, no `metal` shader compiler). See README.md for the pinned commit and patches.
import PackageDescription
import Foundation

// Upstream's Xcode prefix header (imports Cocoa, defines SYPHONLOG) is force-included into every
// source file, exactly as Xcode's GCC_PREFIX_HEADER did. SwiftPM has no prefix-header setting, so
// this uses -include with an absolute path (unsafeFlags are permitted for root and path dependencies).
let prefixHeader = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/Syphon/Syphon_Prefix.h").path

let package = Package(
    name: "Syphon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Syphon", targets: ["Syphon"]),
    ],
    targets: [
        .target(
            name: "Syphon",
            path: "Sources/Syphon",
            exclude: [
                // Compiled at runtime from an embedded copy (see SyphonServerRendererMetal.m).
                // Kept only for reference; SwiftPM would otherwise try to run `metal` on it.
                "SyphonMetalShaders.metal",
            ],
            publicHeadersPath: "include",
            cSettings: [
                // Upstream sources #import private headers by bare name and public headers either
                // by bare name or as <Syphon/...>; both resolve with these search paths.
                .headerSearchPath("include/Syphon"),
                // Upstream Release configuration define (share GL contexts in the Core Profile renderer).
                .define("SYPHON_CORE_SHARE"),
                .unsafeFlags(["-include", prefixHeader]),
                .define("GL_SILENCE_DEPRECATION"),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Cocoa"),
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
                .linkedFramework("OpenGL"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "SyphonSmokeTest",
            dependencies: ["Syphon"],
            path: "Sources/SyphonSmokeTest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
