import CryptoKit
import XCTest

/// Per-app routing's system extension ships inside the app before any routing does (design,
/// section 10 step 4). These are the packaging facts that otherwise show only when macOS
/// activates the extension, or when AMFI kills the signed app on a user's Mac.
final class ExtensionPackagingTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let proxyID = "com.geiserx.vpn-bypass.proxy"
    private static let team = "624WUVM8B4"

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private struct Run { var status: Int32; var out: String; var err: String }

    private func run(_ executable: String, _ args: [String], env: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(env) { $1 }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, out: String(decoding: o, as: UTF8.self),
                   err: String(decoding: e, as: UTF8.self))
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ne-packaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - The extension's bundle

    func testTheExtensionIsASystemExtensionNamingItsProviderClass() throws {
        let info = try plist("Proxy/Info.plist")
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "SYSX")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, Self.proxyID)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, Self.proxyID, "the SwiftPM product's name")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "15.0", "the nw_endpoint_t flow APIs (3.1)")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon", "the approval alert shows the icon")
        XCTAssertNil(info["NEMachServiceName"], "not needed, settled by the spike")
        let ne = try XCTUnwrap(info["NetworkExtension"] as? [String: Any])
        let classes = try XCTUnwrap(ne["NEProviderClasses"] as? [String: String])
        XCTAssertEqual(classes, ["com.apple.networkextension.app-proxy": "FlowProxy"])
        // The class carries that exact Objective-C name, whatever the module is called.
        let source = try text("Sources/VPNBypassProxy/FlowProxy.swift")
        XCTAssertTrue(source.contains("@objc(FlowProxy)\nfinal class FlowProxy: NETransparentProxyProvider"))
        XCTAssertTrue(try text("Package.swift").contains(#".executable(name: "\#(Self.proxyID)", targets: ["VPNBypassProxy"])"#))
    }

    func testTheExtensionNeverLinksTheAppsCore() throws {
        let package = try text("Package.swift")
        let target = try XCTUnwrap(package.range(of: #"name: "VPNBypassProxy","#))
        let rest = package[target.upperBound...]
        let end = try XCTUnwrap(rest.range(of: ")"))
        XCTAssertEqual(rest[..<end.lowerBound].replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: "\n", with: ""),
                       #"dependencies:["VPNBypassPolicy"],path:"Sources/VPNBypassProxy""#,
                       "VPNBypassCore's Bundle.module would trap inside the extension")
    }

    func testTheApprovalAlertTextIsInEveryLanguage() throws {
        let english = try XCTUnwrap(try plist("Proxy/Info.plist")["NSSystemExtensionUsageDescription"] as? String)
        var seen: Set<String> = []
        for language in ["en", "es", "fr"] {
            let strings = try plist("Proxy/\(language).lproj/InfoPlist.strings")
            let value = try XCTUnwrap(strings["NSSystemExtensionUsageDescription"] as? String, language)
            if language == "en" { XCTAssertEqual(value, english) }
            seen.insert(value)
        }
        XCTAssertEqual(seen.count, 3, "Spanish and French are translated, not copies of the English")
        let makefile = try text("Makefile")
        XCTAssertTrue(makefile.contains(#"@cp -R Proxy/*.lproj "$(PROXY_BUNDLE)/Contents/Resources/""#))
    }

    func testTheBundleStepEmbedsTheExtensionWithTheAppsVersion() throws {
        let makefile = try text("Makefile")
        XCTAssertTrue(makefile.contains("PROXY_BUNDLE = $(APP_BUNDLE)/Contents/Library/SystemExtensions/$(PROXY_ID).systemextension"))
        for line in [#"@cp "$(BUILD_DIR)/$(PROXY_ID)" "$(PROXY_BUNDLE)/Contents/MacOS/""#,
                     #"@cp Proxy/Info.plist "$(PROXY_BUNDLE)/Contents/""#,
                     #"Set :CFBundleShortVersionString $(VERSION)" "$(PROXY_BUNDLE)/Contents/Info.plist""#,
                     #"Set :CFBundleVersion $(VERSION)" "$(PROXY_BUNDLE)/Contents/Info.plist""#,
                     #"@cp assets/AppIcon.icns "$(PROXY_BUNDLE)/Contents/Resources/""#,
                     #"@scripts/check-extension-bundle.sh "$(APP_BUNDLE)""#] {
            XCTAssertTrue(makefile.contains(line), line)
        }
    }

    func testTheExtensionLogsNoStrings() throws {
        // Design 3.8: one log function, a fixed event and integers. No other logging call.
        let dir = Self.root.appendingPathComponent("Sources/VPNBypassProxy")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try text("Sources/VPNBypassProxy/\(file)")
            for call in ["NSLog(", "print(", "Logger(", "os_log(", "debugPrint("] where file != "ProxyLog.swift" {
                XCTAssertFalse(source.contains(call), "\(file) logs with \(call)")
            }
        }
        let log = try text("Sources/VPNBypassProxy/ProxyLog.swift")
        XCTAssertTrue(log.contains("static func event(_ e: ProxyEvent, _ a: Int = 0)"))
        XCTAssertFalse(log.contains("String"), "the log function takes no string")
    }

    // MARK: - Entitlements

    private static let relaxations = [
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.get-task-allow",
    ]

    func testTheAppKeepsItsEntitlementsAndGainsTheNetworkExtensionOnes() throws {
        let app = try plist("entitlements/app.entitlements")
        XCTAssertEqual(Set(app.keys), [
            "com.apple.security.app-sandbox", "com.apple.security.network.client",
            "com.apple.security.automation.apple-events",
            "com.apple.application-identifier", "com.apple.developer.team-identifier",
            "com.apple.developer.system-extension.install", "com.apple.developer.networking.networkextension",
        ])
        XCTAssertEqual(app["com.apple.security.app-sandbox"] as? Bool, false)
        XCTAssertEqual(app["com.apple.application-identifier"] as? String, "\(Self.team).com.geiserx.vpn-bypass")
        XCTAssertEqual(app["com.apple.developer.team-identifier"] as? String, Self.team)
        XCTAssertEqual(app["com.apple.developer.system-extension.install"] as? Bool, true)
        XCTAssertEqual(app["com.apple.developer.networking.networkextension"] as? [String],
                       ["app-proxy-provider-systemextension"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("VPNBypass.entitlements").path),
                       "moved to entitlements/app.entitlements")
    }

    func testTheExtensionCarriesOnlyItsProviderEntitlement() throws {
        let proxy = try plist("entitlements/proxy.entitlements")
        XCTAssertEqual(Set(proxy.keys), ["com.apple.application-identifier", "com.apple.developer.team-identifier",
                                         "com.apple.developer.networking.networkextension"])
        XCTAssertEqual(proxy["com.apple.application-identifier"] as? String, "\(Self.team).\(Self.proxyID)")
        XCTAssertEqual(proxy["com.apple.developer.team-identifier"] as? String, Self.team)
        XCTAssertEqual(proxy["com.apple.developer.networking.networkextension"] as? [String],
                       ["app-proxy-provider-systemextension"])
    }

    func testNoBinaryCombinesNetworkExtensionWithARuntimeRelaxation() throws {
        for file in ["entitlements/app.entitlements", "entitlements/proxy.entitlements"] {
            let keys = try plist(file).keys
            for key in Self.relaxations { XCTAssertFalse(keys.contains(key), "\(file) has \(key)") }
        }
    }

    // MARK: - Profiles

    private let certificate = Data("test certificate".utf8)
    private var certificateSHA1: String {
        Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
    }

    private func profile(id: String = "com.geiserx.vpn-bypass", certificates: [Data]? = nil,
                         expires: Date = Date().addingTimeInterval(86_400 * 365), allDevices: Bool = true,
                         networkExtension: [String] = ["app-proxy-provider-systemextension",
                                                       "packet-tunnel-provider-systemextension"],
                         systemExtensionInstall: Bool = true) throws -> URL {
        var entitlements: [String: Any] = [
            "com.apple.application-identifier": "\(Self.team).\(id)",
            "com.apple.developer.team-identifier": Self.team,
            "com.apple.developer.networking.networkextension": networkExtension,
            "keychain-access-groups": ["\(Self.team).*"],
        ]
        if systemExtensionInstall { entitlements["com.apple.developer.system-extension.install"] = true }
        let body: [String: Any] = [
            "Name": "test profile", "TeamIdentifier": [Self.team], "ExpirationDate": expires,
            "ProvisionsAllDevices": allDevices, "DeveloperCertificates": certificates ?? [certificate],
            "Entitlements": entitlements,
        ]
        let url = try temporaryDirectory().appendingPathComponent("profile.plist")
        try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0).write(to: url)
        return url
    }

    private func check(_ profile: URL, id: String = "com.geiserx.vpn-bypass",
                       entitlements: String = "entitlements/app.entitlements", sha1: String? = nil,
                       decoded: Bool = true) throws -> Run {
        try run("/usr/bin/python3", ["-I", Self.root.appendingPathComponent("scripts/check-profile.py").path,
                                     profile.path, "--id", id,
                                     "--entitlements", Self.root.appendingPathComponent(entitlements).path,
                                     "--cert-sha1", sha1 ?? certificateSHA1] + (decoded ? ["--plist"] : []))
    }

    func testAProfileThatFitsPasses() throws {
        let r = try check(try profile())
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("profile ok"), r.out)
        // The SHA-1 is compared without regard to case.
        XCTAssertEqual(try check(try profile(), sha1: certificateSHA1.lowercased()).status, 0)
        let proxy = try check(try profile(id: Self.proxyID, systemExtensionInstall: false), id: Self.proxyID,
                              entitlements: "entitlements/proxy.entitlements")
        XCTAssertEqual(proxy.status, 0, proxy.err)
    }

    /// Each of these gets the signed binary SIGKILLed by AMFI at launch.
    func testAProfileThatDoesNotFitIsRefusedAndSaysWhy() throws {
        let cases: [(URL, String)] = [
            (try profile(id: "com.geiserx.vpn-bypass.spike"), "not 624WUVM8B4.com.geiserx.vpn-bypass"),
            (try profile(certificates: [Data("another certificate".utf8)]), "does not hold the signing certificate"),
            (try profile(expires: Date().addingTimeInterval(-60)), "expired"),
            (try profile(allDevices: false), "not a Developer ID profile"),
            (try profile(networkExtension: ["packet-tunnel-provider-systemextension"]),
             "does not allow com.apple.developer.networking.networkextension"),
            (try profile(systemExtensionInstall: false), "does not allow com.apple.developer.system-extension.install"),
        ]
        for (url, why) in cases {
            let r = try check(url)
            XCTAssertEqual(r.status, 1, why)
            XCTAssertTrue(r.err.contains(why), "\(why): \(r.err)")
        }
        // The app's profile does not fit the extension.
        let r = try check(try profile(), id: Self.proxyID, entitlements: "entitlements/proxy.entitlements")
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("not 624WUVM8B4.com.geiserx.vpn-bypass.proxy"), r.err)
    }

    func testAFileThatIsNoProfileIsRefused() throws {
        let junk = try temporaryDirectory().appendingPathComponent("junk.provisionprofile")
        try Data("not a profile".utf8).write(to: junk)
        var r = try check(junk, decoded: false)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("does not decode"), r.err)
        // A plain plist that would fit is still no profile: AMFI reads only the signed (CMS) file,
        // so without --plist the check refuses it.
        r = try check(try profile(), decoded: false)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("does not decode"), r.err)
        XCTAssertFalse(try text("scripts/sign-and-notarize.sh").contains("--plist"), "signing never skips the CMS check")
    }

    // MARK: - Signing

    func testTheSigningScriptNeedsBothProfilesBeforeItSignsAnything() throws {
        let script = Self.root.appendingPathComponent("scripts/sign-and-notarize.sh").path
        let entitlements = Self.root.appendingPathComponent("entitlements/app.entitlements").path
        let app = try temporaryDirectory().appendingPathComponent("VPN Bypass.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let identity = ["SIGN_IDENTITY": "0000000000000000000000000000000000000000",
                        "APPLE_ID": "a", "APPLE_PASSWORD": "b", "APPLE_TEAM_ID": "c"]
        var r = try run("/bin/bash", [script, "app", "--entitlements", entitlements, app.path], env: identity)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.err.contains("PROVISIONING_PROFILE_APP (path to a provisioning profile) is not set"), r.err)
        var env = identity.merging(["PROVISIONING_PROFILE_APP": entitlements]) { $1 }
        r = try run("/bin/bash", [script, "app", "--entitlements", entitlements, app.path], env: env)
        XCTAssertTrue(r.err.contains("PROVISIONING_PROFILE_PROXY (path to a provisioning profile) is not set"), r.err)
        env["PROVISIONING_PROFILE_PROXY"] = "/nonexistent.provisionprofile"
        r = try run("/bin/bash", [script, "app", "--entitlements", entitlements, app.path], env: env)
        XCTAssertTrue(r.err.contains("PROVISIONING_PROFILE_PROXY: /nonexistent.provisionprofile does not exist"), r.err)
        env["PROVISIONING_PROFILE_PROXY"] = entitlements
        r = try run("/bin/bash", [script, "app", "--entitlements", entitlements, app.path], env: env)
        XCTAssertTrue(r.err.contains("com.geiserx.vpn-bypass.proxy.systemextension is missing"), r.err)
        // app mode without entitlements would sign the app without its Network Extension keys.
        r = try run("/bin/bash", [script, "app", app.path], env: env)
        XCTAssertTrue(r.err.contains("app needs --entitlements"), r.err)
    }

    func testTheSigningScriptSignsInsideOutWithProfilesAndChecksTheResult() throws {
        let script = try text("scripts/sign-and-notarize.sh")
        let order = [
            #"sign --identifier com.geiserx.vpnbypass.helper"#,
            #"sign --identifier com.geiserx.vpn-bypass.vpnb"#,
            #"embed_profile "$PROVISIONING_PROFILE_PROXY" "$proxy_id" "$proxy_entitlements" "$proxy""#,
            #"sign --entitlements "$proxy_entitlements" "$proxy""#,
            #"check_signed_entitlements "$proxy" "$proxy_entitlements""#,
            #"embed_profile "$PROVISIONING_PROFILE_APP" com.geiserx.vpn-bypass "$entitlements" "$target""#,
            #"sign --entitlements "$entitlements" "$target""#,
            #"check_signed_entitlements "$target" "$entitlements""#,
            #"codesign --verify --deep --strict --verbose=2 "$target""#,
            #"codesign --verify -R="$helper_requirement" "$target""#,
            #"codesign --verify -R="$proxy_requirement" "$proxy""#,
            #"notarize "$work/app.zip""#,
        ]
        var from = script.startIndex
        for step in order {
            let found = try XCTUnwrap(script.range(of: step, range: from..<script.endIndex), "missing or out of order: \(step)")
            from = found.upperBound
        }
        XCTAssertTrue(script.contains(#"cp "$1" "$4/Contents/embedded.provisionprofile""#), "AMFI reads that name")
    }

    // MARK: - The launch gate

    /// A fake bundle whose binaries are shell scripts, so the gate's red path runs anywhere.
    private func fakeApp(app appBody: String, extensionBody: String?) throws -> URL {
        let app = try temporaryDirectory().appendingPathComponent("VPN Bypass.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        func script(_ url: URL, _ body: String) throws {
            try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try script(macos.appendingPathComponent("VPNBypass"), appBody)
        try script(macos.appendingPathComponent("vpnb"), "exit 0")
        let info: [String: Any] = ["CFBundleShortVersionString": "6.1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let extensionBody {
            let ext = app.appendingPathComponent(
                "Contents/Library/SystemExtensions/\(Self.proxyID).systemextension/Contents/MacOS")
            try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
            try script(ext.appendingPathComponent(Self.proxyID), extensionBody)
        }
        return app
    }

    private func smokeLaunch(_ app: URL) throws -> Run {
        // Its own HOME: the script clears the control socket under $HOME.
        let home = try temporaryDirectory()
        return try run("/bin/bash", [Self.root.appendingPathComponent("scripts/smoke-launch.sh").path, app.path],
                       env: ["HOME": home.path])
    }

    func testTheGateFailsWhenAMFIKillsTheExtension() throws {
        let r = try smokeLaunch(try fakeApp(app: "exit 0", extensionBody: "kill -KILL $$"))
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.out.contains("the extension was killed at exec (SIGKILL)"), r.out)
    }

    func testTheGateFailsWhenAMFIKillsTheApp() throws {
        let r = try smokeLaunch(try fakeApp(app: "kill -KILL $$", extensionBody: "exit 0"))
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.out.contains("the app was killed at exec (SIGKILL)"), r.out)
    }

    func testAnExtensionThatExitsOutsideSysextdIsNoFailure() throws {
        // Outside sysextd the real extension may exit at once; only a kill is AMFI's verdict. The
        // fake app then dies without its socket, which the gate reports as the app's failure.
        let r = try smokeLaunch(try fakeApp(app: "exit 3", extensionBody: "exit 1"))
        XCTAssertTrue(r.out.contains("Extension binary started and exited with status 1 (not killed)"), r.out)
        XCTAssertTrue(r.out.contains("the app exited during launch (status 3)"), r.out)
    }

    // MARK: - CI and release

    func testTheReleaseDecodesBothProfilesAndLaunchesTheSignedApp() throws {
        let release = try text(".github/workflows/release.yml")
        for secret in ["PROVISIONING_PROFILE_APP_BASE64", "PROVISIONING_PROFILE_PROXY_BASE64"] {
            XCTAssertTrue(release.contains("${{ secrets.\(secret) }}"), secret)
        }
        XCTAssertTrue(release.contains(#"[ -n "${!name}" ] || { echo "::error::secret $name is not set"; exit 1; }"#))
        XCTAssertTrue(release.contains("PROVISIONING_PROFILE_APP: ${{ runner.temp }}/app.provisionprofile"))
        XCTAssertTrue(release.contains("PROVISIONING_PROFILE_PROXY: ${{ runner.temp }}/proxy.provisionprofile"))
        let build = try XCTUnwrap(release.range(of: "run: make release"))
        let gate = try XCTUnwrap(release.range(of: #"run: scripts/smoke-launch.sh "VPN Bypass.app""#))
        let publish = try XCTUnwrap(release.range(of: "name: Create GitHub Release"))
        XCTAssertLessThan(build.lowerBound, gate.lowerBound, "the gate launches the signed app")
        XCTAssertLessThan(gate.lowerBound, publish.lowerBound, "before anything is published")
    }

    func testCIChecksTheExtensionAndReleasesFollowItsFiles() throws {
        let ci = try text(".github/workflows/ci.yml")
        XCTAssertTrue(ci.contains(#""VPN Bypass.app/Contents/Library/SystemExtensions/com.geiserx.vpn-bypass.proxy.systemextension/Contents/MacOS/com.geiserx.vpn-bypass.proxy"; do"#),
                      "the extension is in the universal-architecture loop")
        XCTAssertTrue(ci.contains(#"run: scripts/check-extension-bundle.sh "VPN Bypass.app""#))
        let autoTag = try text(".github/workflows/auto-tag.yml")
        XCTAssertTrue(autoTag.contains("- 'entitlements/**'"))
        XCTAssertTrue(autoTag.contains("- 'Proxy/**'"))
        XCTAssertFalse(autoTag.contains("VPNBypass.entitlements"))
        let ignore = try text(".gitignore").split(separator: "\n").map(String.init)
        XCTAssertTrue(ignore.contains("*.provisionprofile"), "profiles never enter git")
    }

    func testTheProfileScriptRegistersTheRealIDs() throws {
        let script = try text("scripts/asc-profiles.py")
        XCTAssertTrue(script.contains(#""com.geiserx.vpn-bypass": ("vpn-bypass-app", "VPN Bypass app DevID","#))
        XCTAssertTrue(script.contains(#"["SYSTEM_EXTENSION_INSTALL", "NETWORK_EXTENSIONS"]"#))
        XCTAssertTrue(script.contains(#""com.geiserx.vpn-bypass.proxy": ("vpn-bypass-proxy", "VPN Bypass proxy DevID", ["NETWORK_EXTENSIONS"])"#))
        XCTAssertFalse(script.contains("spike"), "the spike's ids stay as they are")
    }
}
