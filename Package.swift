// swift-tools-version: 6.2
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "ZenithBar",
    platforms: [.macOS("27.0")],
    targets: [
        // Private SkyLight declarations. The framework ships with macOS.
        .target(
            name: "CZenithBar",
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]
        ),
        // Kosmos's snapshot, the workspace pills, the clock, the volume glyph, layout and theme.
        // No AppKit, so tests run without a window server.
        .target(name: "ZenithBarCore"),
        // The plugin runner, the log and the text measures the bar and its panel share, apart
        // from the executable so tests can import them. AppKit, so kept out of ZenithBarCore.
        .target(name: "ZenithBarKit", dependencies: ["ZenithBarCore"]),
        // The bar.
        // Its Info.plist is linked into the binary, for Location Services' prompt (docs/network.md).
        .executableTarget(
            name: "zenithbar", dependencies: ["CZenithBar", "ZenithBarCore", "ZenithBarKit"], exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", root + "/Sources/zenithbar/Info.plist"])]
        ),
        .testTarget(name: "ZenithBarCoreTests", dependencies: ["ZenithBarCore"]),
        .testTarget(name: "ZenithBarKitTests", dependencies: ["ZenithBarCore", "ZenithBarKit"]),
        // Measurements of macOS behaviour that the design depends on (docs/overview.md).
        .executableTarget(name: "zenithbar-probe", dependencies: ["CZenithBar"]),
    ]
)
