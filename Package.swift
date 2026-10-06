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
        // Measurements of macOS behaviour that the design depends on (docs/overview.md).
        .executableTarget(name: "zenith-probe", dependencies: ["CZenith"]),
    ]
)
