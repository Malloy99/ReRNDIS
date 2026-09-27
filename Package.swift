// swift-tools-version: 6.1
import PackageDescription

let releaseOptimizations: [SwiftSetting] = [
    .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release))
]

let package = Package(
    name: "ReRNDIS",
    defaultLocalization: "en",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        // Pure protocol logic. No IOKit or networking imports so everything is unit-testable.
        .target(name: "RNDISCore", swiftSettings: releaseOptimizations),
        // C shim exposing if_fake/BPF/NDRV ioctls that Swift cannot import directly.
        .target(name: "CFeth", cSettings: [.unsafeFlags(["-O3"], .when(configuration: .release))]),
        // XPC contract shared by the daemon, CLI, and menu bar app.
        .target(name: "ReRNDISShared", swiftSettings: releaseOptimizations),
        .executableTarget(
            name: "ReRNDISDaemon",
            dependencies: [
                "RNDISCore",
                "CFeth",
                "ReRNDISShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: releaseOptimizations,
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "rerndisctl",
            dependencies: [
                "ReRNDISShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: releaseOptimizations
        ),
        .executableTarget(
            name: "ReRNDISApp",
            dependencies: ["ReRNDISShared"],
            resources: [.process("Resources")],
            swiftSettings: releaseOptimizations
        ),
        // Throwaway milestone spikes. Removed once the daemon absorbs their learnings.
        .executableTarget(
            name: "SpikeUSB",
            dependencies: ["RNDISCore"],
            linkerSettings: [.linkedFramework("IOUSBHost")]
        ),
        .executableTarget(name: "SpikeFeth", dependencies: ["CFeth"]),
        .testTarget(name: "RNDISCoreTests", dependencies: ["RNDISCore"]),
        .testTarget(name: "ReRNDISAppTests", dependencies: ["ReRNDISApp"]),
    ]
)
