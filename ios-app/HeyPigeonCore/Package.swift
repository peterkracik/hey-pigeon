// swift-tools-version:6.0
// Wraps the Rust core for Swift: the generated UniFFI bindings
// (Sources/HeyPigeonCore/HeyPigeonCore.swift) over the static library
// xcframework. Both are produced by ../scripts/build-rust.sh and git-ignored.
import PackageDescription

let package = Package(
    name: "HeyPigeonCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HeyPigeonCore", targets: ["HeyPigeonCore"]),
    ],
    targets: [
        .binaryTarget(name: "HeyPigeonCoreFFI", path: "HeyPigeonCoreFFI.xcframework"),
        .target(
            name: "HeyPigeonCore",
            dependencies: ["HeyPigeonCoreFFI"],
            path: "Sources/HeyPigeonCore"
        ),
    ]
)
