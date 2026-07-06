// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Glass",
    platforms: [
        .macOS(.v15)
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
        ),
        .executable(
            name: "GlassMac",
            targets: ["GlassMac"]
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
            ]
        ),
        .executableTarget(
            name: "GlassMac",
            dependencies: ["GlassRemoteUI"]
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
        )
    ],
    swiftLanguageModes: [.v6]
)
