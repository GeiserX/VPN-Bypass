// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VPNBypass",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VPNBypass", targets: ["VPNBypass"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "VPNBypass",
            dependencies: [],
            path: ".",
            exclude: [
                "AGENTS.md", "Casks", "Helper", "Info.plist", "LICENSE",
                "Makefile", "README.md", "ROADMAP.md", "SECURITY.md",
                "VPN Bypass.app", "VPNBypass.entitlements", "assets",
                "dist", "docs", "scripts", "Tests"
            ],
            sources: ["Sources"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "VPNBypassTests",
            dependencies: [],
            path: "Tests/VPNBypassTests",
            sources: ["VPNBypassTests.swift"]
        )
    ]
)
