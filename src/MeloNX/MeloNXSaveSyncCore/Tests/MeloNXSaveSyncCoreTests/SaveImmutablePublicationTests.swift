import XCTest
@testable import MeloNXSaveSyncCore

final class SaveImmutablePublicationTests: XCTestCase {
    func testResumeAcceptsMatchingFilesAndRejectsConflictingBytesOrLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("version/payload")
        try Data([1, 2, 3]).write(to: source)
        try SaveImmutablePublication.copy(source: source, destination: target)
        try SaveImmutablePublication.copy(source: source, destination: target)
        try Data([1, 2, 4]).write(to: target)
        XCTAssertThrowsError(try SaveImmutablePublication.copy(source: source, destination: target))
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 4]))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        XCTAssertThrowsError(try SaveImmutablePublication.copy(source: source, destination: target))
    }
}
