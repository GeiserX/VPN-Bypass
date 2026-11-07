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
        .executable(name: "vpnb", targets: ["vpnb"]),
        // Per-app routing's system extension. The product name is the bundle's executable name
        // (Proxy/Info.plist CFBundleExecutable); `make bundle` puts it in the .systemextension.
        .executable(name: "com.geiserx.vpn-bypass.proxy", targets: ["VPNBypassProxy"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VPNBypassPeerAuth",
            path: "Sources/VPNBypassPeerAuth",
            publicHeadersPath: "include"
        ),
        // Per-app routing's policy: pure, Foundation only, no resources, so the Network Extension
        // can link it without VPNBypassCore (whose Bundle.module would trap there).
        .target(
            name: "VPNBypassPolicy",
            path: "Sources/VPNBypassPolicy"
        ),
        .target(
            name: "VPNBypassCore",
            dependencies: ["VPNBypassPeerAuth", "VPNBypassPolicy"],
            path: "Sources/VPNBypassCore",
            exclude: ["Resources/catalogue/README.md"],
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
        // Links VPNBypassPolicy and the system frameworks only, never VPNBypassCore: that target
        // has resources, and its Bundle.module accessor would trap inside the extension.
        .executableTarget(
            name: "VPNBypassProxy",
            dependencies: ["VPNBypassPolicy"],
            path: "Sources/VPNBypassProxy"
        ),
        .testTarget(
            name: "VPNBypassTests",
            dependencies: ["VPNBypassCore", "VPNBypassPolicy"],
            path: "Tests/VPNBypassTests"
        ),
        .testTarget(
            name: "VPNBypassPolicyTests",
            dependencies: ["VPNBypassPolicy"],
            path: "Tests/VPNBypassPolicyTests"
        )
    ]
)
