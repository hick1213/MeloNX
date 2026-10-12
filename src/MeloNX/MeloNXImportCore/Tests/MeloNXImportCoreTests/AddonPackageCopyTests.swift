import XCTest
@testable import MeloNXImportCore

final class AddonPackageCopyTests: XCTestCase {
    func testRejectedDlcDoesNotCopyOrCreateDestinationDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("update.nsp")
        try Data([1, 2, 3]).write(to: source)
        let destination = root.appendingPathComponent("dlc/game/update.nsp")
        XCTAssertThrowsError(try AddonPackageCopy.copy(source: source, destination: destination) {
            throw CocoaError(.fileReadCorruptFile)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    func testExistingDestinationIsNeverRemovedOrOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("incoming.nsp"), destination = root.appendingPathComponent("existing.nsp")
        try Data([1]).write(to: source); try Data([9]).write(to: destination)
        XCTAssertThrowsError(try AddonPackageCopy.copy(source: source, destination: destination, validate: {}))
        XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
    }

    func testAcceptedPackageCopiesExactBytesAndPreservesSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.nsp"), destination = root.appendingPathComponent("updates/game/update.nsp")
        let bytes = Data([0, 1, 2, 255]); try bytes.write(to: source)
        try AddonPackageCopy.copy(source: source, destination: destination, validate: {})
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testRegistrationRetryReusesOnlyIdenticalExistingCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.nsp"), destination = root.appendingPathComponent("copy.nsp")
        try Data([1, 2]).write(to: source); try Data([1, 2]).write(to: destination)
        try AddonPackageCopy.copy(source: source, destination: destination, validate: {})
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2]))
    }

    func testCopyFailureLeavesNoPartialFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("updates/game.nsp")
        XCTAssertThrowsError(try AddonPackageCopy.copy(source: root.appendingPathComponent("missing.nsp"), destination: destination, validate: {}))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), [])
    }
}
