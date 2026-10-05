import XCTest
@testable import VPNBypassCore

final class HostsFileModeTests: XCTestCase {
    private func tempFile(mode: Int) throws -> String {
        let path = NSTemporaryDirectory() + "hosts-mode-\(UUID().uuidString)"
        XCTAssertTrue(FileManager.default.createFile(
            atPath: path, contents: Data("127.0.0.1 localhost\n".utf8),
            attributes: [.posixPermissions: mode]))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testWorldReadableFileIsReadable() throws {
        let path = try tempFile(mode: 0o644)
        XCTAssertTrue(HostsFileMode.isWorldReadable(path: path))
        XCTAssertEqual(HostsFileMode.octalMode(path: path), "0644")
    }

    func testOwnerAndGroupOnlyFileIsNotReadable() throws {
        // The mode another tool left /etc/hosts in on 2026-10-05.
        let path = try tempFile(mode: 0o440)
        XCTAssertFalse(HostsFileMode.isWorldReadable(path: path))
        XCTAssertEqual(HostsFileMode.octalMode(path: path), "0440")
    }

    func testMissingFileIsNotReadable() {
        let path = NSTemporaryDirectory() + "hosts-mode-missing-\(UUID().uuidString)"
        XCTAssertFalse(HostsFileMode.isWorldReadable(path: path))
        XCTAssertNil(HostsFileMode.octalMode(path: path))
    }
}
