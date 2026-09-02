import Foundation
import XCTest
@testable import SpiekCore

/// P0.6 (v1.21): the store folder — database, WAL and SHM sidecars, anything
/// written beside them — is excluded from backups and (on iOS) sealed with
/// `completeUntilFirstUserAuthentication`. Opening the store applies it;
/// re-applying after a write covers sidecars SQLite recreated meanwhile.
final class StorageProtectionTests: XCTestCase {

    private func temporaryFolder() -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spiek-protect-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testOpeningTheStoreProtectsDatabaseAndSidecars() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("spiek.sqlite")

        let store = try Store(url: url)
        // A write forces the WAL/SHM sidecars into existence.
        try await store.putMeta(key: "probe", value: "x")
        try await store.reapplyProtection(folder: folder)

        for name in ["spiek.sqlite", "spiek.sqlite-wal", "spiek.sqlite-shm"] {
            let file = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            XCTAssertTrue(StorageProtection.isProtected(file), "\(name) is not protected")
        }
        XCTAssertTrue(StorageProtection.isProtected(folder), "the folder itself is not protected")
    }

    func testFilesCreatedLaterAreCoveredOnReapply() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try StorageProtection.apply(to: folder)

        // A cache file that appears after the first pass — e.g. a recreated
        // sidecar or a media thumbnail — must be picked up by the next apply.
        let late = folder.appendingPathComponent("thumbs").appendingPathComponent("late.bin")
        try FileManager.default.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: late)
        try StorageProtection.apply(to: folder)
        XCTAssertTrue(StorageProtection.isProtected(late))
        XCTAssertTrue(StorageProtection.isProtected(late.deletingLastPathComponent()))
    }

    func testMissingFolderFailsClosed() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        #if canImport(Darwin)
        XCTAssertThrowsError(try StorageProtection.apply(to: missing),
                             "a folder we cannot protect must throw, never be ignored")
        #endif
    }
}
