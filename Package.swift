// swift-tools-version:6.0
// The Swift equivalent of package.json. `swift build` / `swift test` read this.
import PackageDescription

let package = Package(
    name: "Curtain",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure Swift: the cloth simulation and all tunable numbers. No AppKit,
        // so it can be unit-tested without a window or a GPU.
        .target(name: "CurtainCore"),

        // The menu bar app: overlay window, Metal rendering, mouse input.
        // Info.plist and Shaders.metal are copied into the .app by the Makefile,
        // so SwiftPM is told to leave them alone.
        .executableTarget(
            name: "Curtain",
            dependencies: ["CurtainCore"],
            exclude: ["Info.plist", "Shaders.metal"]
        ),

        .testTarget(name: "CurtainCoreTests", dependencies: ["CurtainCore"]),
    ],
    // Swift 6's strict concurrency checking adds a lot of ceremony around
    // AppKit (everything must be proven main-thread). Language mode 5 keeps
    // the code readable; the app is single-threaded anyway.
    swiftLanguageModes: [.v5]
)
