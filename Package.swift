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
        .target(
            name: "VPNBypassCore",
            dependencies: [],
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
        .testTarget(
            name: "VPNBypassTests",
            dependencies: ["VPNBypassCore"],
            path: "Tests/VPNBypassTests"
        )
    ]
)
