// swift-tools-version:6.4
// 6.4: the first PackageDescription with `.iOS(.v27)` / `.macOS(.v27)`
// (Xcode 27). 6.2 rejected them as unavailable (publish-ios run 93).
// Wraps the Rust core for Swift: the generated UniFFI bindings
// (Sources/HeyPigeonCore/HeyPigeonCore.swift) over the static library
// xcframework. Both are produced by ../scripts/build-rust.sh and git-ignored.
import PackageDescription

let package = Package(
    name: "HeyPigeonCore",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "HeyPigeonCore", targets: ["HeyPigeonCore"]),
    ],
    targets: [
        .binaryTarget(name: "HeyPigeonCoreFFI", path: "HeyPigeonCoreFFI.xcframework"),
        .target(
            name: "HeyPigeonCore",
            dependencies: ["HeyPigeonCoreFFI"],
            path: "Sources/HeyPigeonCore",
            // The generated bindings are UniFFI's code, not ours: its async
            // callback-interface scaffolding (`uniffiTraitInterfaceCallAsync`,
            // used by the AiBackend trait) passes a non-Sendable closure into a
            // Task, which Swift 6 language mode rejects outright. Swift 5 mode
            // keeps that a warning; the app target itself stays on Swift 6.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
