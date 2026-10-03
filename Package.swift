// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Glass",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(
            name: "GlassRemoteCore",
            targets: ["GlassRemoteCore"]
        ),
        .library(
            name: "GlassRemoteServices",
            targets: ["GlassRemoteServices"]
        ),
        .library(
            name: "GlassRemoteUI",
            targets: ["GlassRemoteUI"]
        )
    ],
    targets: [
        .target(name: "GlassRemoteCore"),
        .target(
            name: "GlassRemoteServices",
            dependencies: ["GlassRemoteCore"]
        ),
        .target(
            name: "GlassRemoteUI",
            dependencies: [
                "GlassRemoteCore",
                "GlassRemoteServices"
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GlassRemoteCoreTests",
            dependencies: ["GlassRemoteCore"]
        ),
        .testTarget(
            name: "GlassRemoteServicesTests",
            dependencies: [
                "GlassRemoteCore",
                "GlassRemoteServices"
            ]
        ),
        .testTarget(
            name: "GlassRemoteUITests",
            dependencies: ["GlassRemoteUI", "GlassRemoteServices", "GlassRemoteCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
