// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Zenith",
    platforms: [.macOS("27.0")],
    targets: [
        // Private SkyLight declarations. The framework ships with macOS.
        .target(
            name: "CZenith",
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]
        ),
        // Kosmos's snapshot, the workspace pills, the clock, the volume glyph, layout and theme.
        // No AppKit, so tests run without a window server.
        .target(name: "ZenithCore"),
        // The plugin runner, the log and the text measures the bar and its panel share, apart
        // from the executable so tests can import them. AppKit, so kept out of ZenithCore.
        .target(name: "ZenithKit", dependencies: ["ZenithCore"]),
        // The bar.
        .executableTarget(name: "zenith", dependencies: ["CZenith", "ZenithCore", "ZenithKit"]),
        .testTarget(name: "ZenithCoreTests", dependencies: ["ZenithCore"]),
        .testTarget(name: "ZenithKitTests", dependencies: ["ZenithCore", "ZenithKit"]),
        // Measurements of macOS behaviour that the design depends on (docs/overview.md).
        .executableTarget(name: "zenith-probe", dependencies: ["CZenith"]),
    ]
)
