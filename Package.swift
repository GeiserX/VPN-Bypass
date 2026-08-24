// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VPNBypass",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VPNBypass", targets: ["VPNBypass"]),
        .executable(name: "vpnb", targets: ["vpnb"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VPNBypassPeerAuth",
            path: "Sources/VPNBypassPeerAuth",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VPNBypassCore",
            dependencies: ["VPNBypassPeerAuth"],
            path: "Sources/VPNBypassCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "VPNBypass",
            dependencies: ["VPNBypassCore"],
            path: "Sources/VPNBypass"
        ),
        .executableTarget(
            name: "vpnb",
            dependencies: ["VPNBypassCore"],
            path: "Sources/vpnb"
        ),
        .testTarget(
            name: "VPNBypassTests",
            dependencies: ["VPNBypassCore"],
            path: "Tests/VPNBypassTests"
        )
    ]
)
