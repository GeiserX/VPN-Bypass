// HelperSelfUpdateTests.swift
// A helper from 2.8.0 on installs the next helper from the app bundle itself, so an update
// needs no administrator password. These cover which path an update takes, the fallback to the
// password when the helper cannot do it, and the checks the helper runs before it replaces
// itself (signature, version, file type), on temporary files.

import XCTest
@testable import VPNBypassCore

// MARK: - Which path an update takes

final class HelperUpdatePathTests: XCTestCase {

    private let plist = Data("<plist>same</plist>".utf8)

    func testA28HelperUnderTheShippedPlistUpdatesItself() {
        XCTAssertEqual(HelperManager.updatePath(running: "2.8.0", installedPlist: plist, bundledPlist: plist), .selfUpdate)
        XCTAssertEqual(HelperManager.updatePath(running: "2.10.1", installedPlist: plist, bundledPlist: plist), .selfUpdate)
    }

    func testAHelperWithoutTheCallNeedsThePassword() {
        XCTAssertEqual(HelperManager.updatePath(running: "2.7.0", installedPlist: plist, bundledPlist: plist), .adminPassword)
        XCTAssertEqual(HelperManager.updatePath(running: "2.6.0", installedPlist: plist, bundledPlist: plist), .adminPassword)
    }

    /// The helper replaces only its binary; a plist that changed needs the full installer.
    func testAChangedOrMissingPlistNeedsThePassword() {
        let other = Data("<plist>other</plist>".utf8)
        XCTAssertEqual(HelperManager.updatePath(running: "2.8.0", installedPlist: plist, bundledPlist: other), .adminPassword)
        XCTAssertEqual(HelperManager.updatePath(running: "2.8.0", installedPlist: nil, bundledPlist: plist), .adminPassword)
        XCTAssertEqual(HelperManager.updatePath(running: "2.8.0", installedPlist: plist, bundledPlist: nil), .adminPassword)
    }
}

// MARK: - The checks the helper runs before it replaces itself

final class HelperSelfUpdateInstallTests: XCTestCase {

    private var dir: URL!
    private var destination: String { dir.appendingPathComponent("com.geiserx.vpnbypass.helper").path }
    private let oldHelper = Data("old helper".utf8)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("selfupdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try oldHelper.write(to: URL(fileURLWithPath: destination))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The destination is the running helper's file: a refused update must leave it as it was
    /// and leave no staging copy behind.
    private func assertUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(FileManager.default.contents(atPath: destination), oldHelper, "the installed helper changed", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination + ".update"), "a staging copy was left", file: file, line: line)
    }

    /// An Apple binary that carries a version in its signed Info.plist, present on every macOS
    /// we support. Stands in for a signed helper in the tests that need one.
    private func appleBinaryWithVersion() throws -> (path: String, version: String) {
        for path in ["/usr/libexec/airportd", "/usr/libexec/appleaccountd", "/usr/libexec/asktod"]
        where FileManager.default.fileExists(atPath: path) {
            if case .success(let version) = HelperSelfUpdate.verifiedVersion(at: path, requirement: "anchor apple") {
                return (path, version)
            }
        }
        throw XCTSkip("no Apple binary with a versioned Info.plist found")
    }

    func testTheRequirementNamesTheHelperAndOurTeam() {
        XCTAssertEqual(HelperSelfUpdate.candidateRequirement,
                       #"anchor apple generic and identifier "com.geiserx.vpnbypass.helper" and certificate leaf[subject.OU] = "624WUVM8B4""#)
    }

    func testVersionsCompareNumerically() {
        XCTAssertTrue(HelperSelfUpdate.isNewer("2.8.0", than: "2.7.0"))
        XCTAssertTrue(HelperSelfUpdate.isNewer("2.10.0", than: "2.9.9"))
        XCTAssertTrue(HelperSelfUpdate.isNewer("3", than: "2.99"))
        XCTAssertFalse(HelperSelfUpdate.isNewer("2.8.0", than: "2.8.0"), "the same version is not an update")
        XCTAssertFalse(HelperSelfUpdate.isNewer("2.8", than: "2.8.0"))
        XCTAssertFalse(HelperSelfUpdate.isNewer("2.7.9", than: "2.8.0"), "never back to an older helper")
    }

    func testAnUnsignedFileIsRefused() throws {
        let source = dir.appendingPathComponent("unsigned").path
        try Data(repeating: 0xCF, count: 4096).write(to: URL(fileURLWithPath: source))

        let result = HelperSelfUpdate.install(from: source, over: destination, running: "2.8.0")

        guard case .failure(.badSignature) = result else { return XCTFail("\(result)") }
        assertUntouched()
    }

    /// Signed and versioned, but by Apple, not by our team as the helper.
    func testABinarySignedBySomeoneElseIsRefused() throws {
        let apple = try appleBinaryWithVersion()

        let result = HelperSelfUpdate.install(from: apple.path, over: destination, running: "0.1")

        guard case .failure(.badSignature) = result else { return XCTFail("\(result)") }
        assertUntouched()
    }

    /// The same check with a requirement the file meets: the copy lands, root-only mode, and
    /// the version comes from the signed Info.plist.
    func testAPassingNewerBinaryReplacesTheHelper() throws {
        let apple = try appleBinaryWithVersion()

        let result = HelperSelfUpdate.install(from: apple.path, over: destination, running: "0.1", requirement: "anchor apple")

        XCTAssertEqual(result, .success(apple.version))
        XCTAssertEqual(FileManager.default.contents(atPath: destination), FileManager.default.contents(atPath: apple.path))
        let mode = try FileManager.default.attributesOfItem(atPath: destination)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o544)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination + ".update"))
    }

    /// A caller cannot roll the helper back to an older signed build, nor reinstall the same one.
    func testAnOlderOrEqualVersionIsRefused() throws {
        let apple = try appleBinaryWithVersion()

        for running in ["99.0", apple.version] {
            let result = HelperSelfUpdate.install(from: apple.path, over: destination, running: running, requirement: "anchor apple")
            XCTAssertEqual(result, .failure(.notNewer(candidate: apple.version, running: running)))
            assertUntouched()
        }
    }

    func testADirectoryOrAMissingFileIsRefused() {
        XCTAssertEqual(HelperSelfUpdate.install(from: dir.path, over: destination, running: "2.8.0"), .failure(.notARegularFile))
        guard case .failure(.unreadable) = HelperSelfUpdate.install(from: dir.appendingPathComponent("missing").path,
                                                                    over: destination, running: "2.8.0") else {
            return XCTFail("a missing file must be unreadable")
        }
        assertUntouched()
    }

    /// A FIFO would block a plain read forever and hang the helper; a symlink is not followed.
    func testAFifoOrASymlinkIsRefusedWithoutBlocking() throws {
        let fifo = dir.appendingPathComponent("fifo").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertEqual(HelperSelfUpdate.install(from: fifo, over: destination, running: "2.8.0"), .failure(.notARegularFile))

        let target = dir.appendingPathComponent("target").path
        try Data(repeating: 0xCF, count: 16).write(to: URL(fileURLWithPath: target))
        let link = dir.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        guard case .failure(.unreadable) = HelperSelfUpdate.install(from: link, over: destination, running: "2.8.0") else {
            return XCTFail("a symlink must not be followed")
        }
        assertUntouched()
    }

    func testAnOversizedFileIsNotRead() throws {
        let source = dir.appendingPathComponent("huge").path
        FileManager.default.createFile(atPath: source, contents: nil)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: source))
        try handle.truncate(atOffset: UInt64(HelperSelfUpdate.maxCandidateBytes + 1))   // sparse
        try handle.close()

        XCTAssertEqual(HelperSelfUpdate.install(from: source, over: destination, running: "2.8.0"),
                       .failure(.tooLarge(HelperSelfUpdate.maxCandidateBytes + 1)))
        assertUntouched()
    }
}

// MARK: - The update flow in the app

@MainActor
final class HelperSelfUpdateFlowTests: XCTestCase {

    private var hm: HelperManager { HelperManager.shared }
    private var rm: RouteManager { RouteManager.shared }
    private var saved: (state: HelperState, version: String?, pending: HelperManager.PendingUpdate?, error: String?,
                        install: @Sendable () -> HelperManager.AdminInstallOutcome,
                        plists: () -> (installed: Data?, bundled: Data?), logs: [RouteManager.LogEntry])!
    private var reapplies = 0
    private var savedDelays: [TimeInterval] = []
    private var selfUpdateCalls: [String] = []
    private let plist = Data("<plist>shipped</plist>".utf8)

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    override func setUp() async throws {
        saved = (hm.helperState, hm.helperVersion, hm.pendingUpdate, hm.installationError, HelperManager.adminInstall,
                 hm.launchdPlists, rm.recentLogs)
        hm.pendingUpdate = nil
        hm.helperState = .checking
        reapplies = 0
        selfUpdateCalls = []
        hm.reapplyRoutesAfterUpdate = { [weak self] in self?.reapplies += 1 }
        let shipped = plist
        hm.launchdPlists = { (shipped, shipped) }
        savedDelays = hm.selfUpdateRestartDelays
        hm.selfUpdateRestartDelays = [0, 0, 0]
        rm.recentLogs = []
    }

    override func tearDown() async throws {
        await hm.updateTask?.value
        HelperManager.adminInstall = saved.install
        hm.launchdPlists = saved.plists
        hm.versionProbeOverrideForTests = nil
        hm.selfUpdateOverrideForTests = nil
        hm.selfUpdateRestartDelays = savedDelays
        hm.reapplyRoutesAfterUpdate = { await RouteManager.shared.reapplyAfterHelperUpdate() }
        hm.helperState = saved.state
        hm.helperVersion = saved.version
        hm.pendingUpdate = saved.pending
        hm.installationError = saved.error
        rm.recentLogs = saved.logs
    }

    private func logLines(containing text: String) -> [String] {
        rm.recentLogs.map(\.message).filter { $0.contains(text) }
    }

    /// The helper answers `before` until the install (self-update or password) ran, then `after`.
    private func helperAnswers(_ before: String, then after: String) -> Counter {
        let installs = Counter()
        hm.versionProbeOverrideForTests = { .version(installs.count > 0 ? after : before) }
        return installs
    }

    func testA28HelperUpdatesWithoutThePasswordPrompt() async throws {
        let installs = helperAnswers("2.8.0", then: "2.9.0")
        let prompts = Counter()
        HelperManager.adminInstall = { prompts.increment(); return .installed }
        hm.selfUpdateOverrideForTests = { [weak self] path in self?.selfUpdateCalls.append(path); installs.increment(); return nil }

        XCTAssertTrue(hm.adoptOlderHelperAndUpdate(installed: "2.8.0", expected: "2.9.0"))
        XCTAssertNil(hm.pendingUpdate, "no 'waiting for your password' while the helper updates itself")
        await hm.updateTask?.value

        XCTAssertEqual(prompts.count, 0, "no administrator password prompt")
        XCTAssertEqual(selfUpdateCalls.count, 1)
        XCTAssertTrue(selfUpdateCalls.first?.hasSuffix("/Contents/MacOS/com.geiserx.vpnbypass.helper") ?? false, selfUpdateCalls.first ?? "nil")
        XCTAssertTrue(hm.helperState.isReady)
        XCTAssertEqual(hm.helperVersion, "2.9.0")
        XCTAssertNil(hm.pendingUpdate)
        XCTAssertNil(hm.installationError)
        XCTAssertEqual(reapplies, 1, "routes are applied again through the new helper")
        XCTAssertEqual(logLines(containing: "no password needed").count, 1)
    }

    /// The old helper still answers for a moment after its yes (it exits 0.5 s later), then the
    /// job is unreachable until launchd starts the new file: the app waits for the new version
    /// instead of reading the old one as a failed update and asking for the password.
    func testTheOldHelperAnsweringUntilItExitsDoesNotPrompt() async throws {
        let updated = Counter(), probesAfter = Counter()
        hm.versionProbeOverrideForTests = {
            guard updated.count > 0 else { return .version("2.8.0") }
            probesAfter.increment()
            switch probesAfter.count {
            case 1: return .version("2.8.0")
            case 2: return .unreachable
            default: return .version("2.9.0")
            }
        }
        let prompts = Counter()
        HelperManager.adminInstall = { prompts.increment(); return .installed }
        hm.selfUpdateOverrideForTests = { _ in updated.increment(); return nil }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.8.0", expected: "2.9.0")
        await hm.updateTask?.value

        XCTAssertEqual(prompts.count, 0, "no password prompt while the old helper is still exiting")
        XCTAssertEqual(hm.helperVersion, "2.9.0")
        XCTAssertTrue(hm.helperState.isReady)
        XCTAssertEqual(probesAfter.count, 3)
    }

    /// The helper refused (a signature or version check, an XPC error): the password installer
    /// runs once, as before this change, and the reason is logged once.
    func testARefusedSelfUpdateFallsBackToThePasswordOnce() async throws {
        let installs = helperAnswers("2.8.0", then: "2.9.0")
        let prompts = Counter()
        HelperManager.adminInstall = { prompts.increment(); installs.increment(); return .installed }
        hm.selfUpdateOverrideForTests = { _ in "the new helper is not signed by our team as the helper (OSStatus -67050)" }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.8.0", expected: "2.9.0")
        await hm.updateTask?.value

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(hm.helperVersion, "2.9.0")
        XCTAssertNil(hm.pendingUpdate)
        XCTAssertEqual(logLines(containing: "did not update itself").count, 1)
    }

    /// The helper said yes but the old version still answers: nothing is trusted on its word,
    /// the password installer runs.
    func testASelfUpdateThatChangedNothingFallsBack() async throws {
        let prompts = Counter()
        hm.versionProbeOverrideForTests = { .version(prompts.count > 0 ? "2.9.0" : "2.8.0") }
        HelperManager.adminInstall = { prompts.increment(); return .installed }
        hm.selfUpdateOverrideForTests = { _ in nil }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.8.0", expected: "2.9.0")
        await hm.updateTask?.value

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(hm.helperVersion, "2.9.0")
        XCTAssertEqual(logLines(containing: "instead of v2.9.0").count, 1)
    }

    /// A cancelled fallback prompt leaves the older helper routing, exactly as a cancelled
    /// password update did before.
    func testACancelledFallbackKeepsTheOlderHelper() async throws {
        hm.versionProbeOverrideForTests = { .version("2.8.0") }
        HelperManager.adminInstall = { .cancelled }
        hm.selfUpdateOverrideForTests = { _ in "the helper did not answer" }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.8.0", expected: "2.9.0")
        await hm.updateTask?.value

        XCTAssertTrue(hm.helperState.isReady)
        XCTAssertEqual(hm.pendingUpdate, .notInstalled(installed: "2.8.0", expected: "2.9.0", reason: .cancelled))
    }

    func testAHelperOlderThan28StillAsksForThePassword() async throws {
        let installs = helperAnswers("2.7.0", then: "2.8.0")
        let prompts = Counter()
        HelperManager.adminInstall = { prompts.increment(); installs.increment(); return .installed }
        hm.selfUpdateOverrideForTests = { [weak self] path in self?.selfUpdateCalls.append(path); return nil }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.7.0", expected: "2.8.0")
        XCTAssertEqual(hm.pendingUpdate, .waiting(installed: "2.7.0", expected: "2.8.0"))
        await hm.updateTask?.value

        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(selfUpdateCalls.isEmpty, "a 2.7.0 helper has no such call")
        XCTAssertEqual(hm.helperVersion, "2.8.0")
    }

    func testAChangedLaunchdPlistStillAsksForThePassword() async throws {
        let installs = helperAnswers("2.8.0", then: "2.9.0")
        let prompts = Counter()
        HelperManager.adminInstall = { prompts.increment(); installs.increment(); return .installed }
        hm.selfUpdateOverrideForTests = { [weak self] path in self?.selfUpdateCalls.append(path); return nil }
        hm.launchdPlists = { (Data("<plist>old</plist>".utf8), Data("<plist>new</plist>".utf8)) }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.8.0", expected: "2.9.0")
        await hm.updateTask?.value

        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(selfUpdateCalls.isEmpty)
    }
}
