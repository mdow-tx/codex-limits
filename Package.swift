// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexLimits",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Codex Limits", targets: ["CodexLimitsApp"]),
        .executable(name: "codex-limits-probe", targets: ["CodexLimitsProbe"]),
        .library(name: "CodexLimitsCore", targets: ["CodexLimitsCore"])
    ],
    targets: [
        .target(name: "CodexLimitsCore"),
        .executableTarget(
            name: "CodexLimitsApp",
            dependencies: ["CodexLimitsCore"],
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "CodexLimitsProbe",
            dependencies: ["CodexLimitsCore"]
        ),
        .testTarget(
            name: "CodexLimitsCoreTests",
            dependencies: ["CodexLimitsCore"]
        )
    ]
)
