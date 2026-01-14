// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VPNBypass",
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
            path: "Sources"
        )
    ]
)
