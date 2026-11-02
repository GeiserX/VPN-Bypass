// swift-tools-version:5.9
// Network Extension spike. Its own package on purpose: nothing here is linked into the shipping app.
import Foundation
import PackageDescription

// spike-fetch is a bare executable, so its Info.plist (bundle id, and App Transport Security allowing
// the test's http:// pages) is linked into the binary as the __TEXT,__info_plist section.
let fetchInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("bundle/Fetch-Info.plist").path

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
        .executableTarget(name: "SpikeFetch", path: "Sources/SpikeFetch",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                                         "-Xlinker", "__info_plist", "-Xlinker", fetchInfoPlist])]),
        .testTarget(name: "SpikePolicyTests", dependencies: ["SpikePolicy"], path: "Tests/SpikePolicyTests"),
    ]
)
