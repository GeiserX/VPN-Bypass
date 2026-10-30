// swift-tools-version:5.9
// Network Extension spike. Its own package on purpose: nothing here is linked into the shipping app.
import PackageDescription

let package = Package(
    name: "NEProxySpike",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "VPNBypassNESpike", targets: ["SpikeApp"]),
        .executable(name: "com.geiserx.vpn-bypass.spike.proxy", targets: ["SpikeProxy"]),
        .executable(name: "spike-fetch", targets: ["SpikeFetch"]),
    ],
    targets: [
        // Pure: policy, matching and verdicts. No NetworkExtension import, so it is unit-tested.
        .target(name: "SpikePolicy", path: "Sources/SpikePolicy"),
        .executableTarget(name: "SpikeProxy", dependencies: ["SpikePolicy"], path: "Sources/SpikeProxy"),
        .executableTarget(name: "SpikeApp", dependencies: ["SpikePolicy"], path: "Sources/SpikeApp"),
        .executableTarget(name: "SpikeFetch", path: "Sources/SpikeFetch"),
        .testTarget(name: "SpikePolicyTests", dependencies: ["SpikePolicy"], path: "Tests/SpikePolicyTests"),
    ]
)
