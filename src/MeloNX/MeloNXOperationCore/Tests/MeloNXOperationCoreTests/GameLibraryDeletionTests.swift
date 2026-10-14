import Foundation
import XCTest
@testable import MeloNXOperationCore

final class GameLibraryDeletionTests: XCTestCase {
    private struct Game: Equatable {
        let fileURL: URL
        let titleID: String
    }

    @MainActor func testSuccessfulDeletionRemovesOnlyTheDeletedFileFromLibrary() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deleted = Game(fileURL: directory.appendingPathComponent("first.nsp"), titleID: "same-title")
        let retained = Game(fileURL: directory.appendingPathComponent("second.xci"), titleID: "same-title")
        try Data([1]).write(to: deleted.fileURL)
        try Data([2]).write(to: retained.fileURL)
        let save = directory.appendingPathComponent("save.bin")
        try Data([3]).write(to: save)
        var games = [deleted, retained]

        try GameLibraryDeletion.delete(at: deleted.fileURL, from: &games, fileURL: \.fileURL)

        XCTAssertEqual(games, [retained])
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: retained.fileURL), Data([2]))
        XCTAssertEqual(try Data(contentsOf: save), Data([3]))
    }

    @MainActor func testFailedDeletionPreservesLibraryAndOtherFiles() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = Game(fileURL: directory.appendingPathComponent("missing.nsp"), titleID: "first")
        let retained = Game(fileURL: directory.appendingPathComponent("retained.xci"), titleID: "second")
        try Data([2]).write(to: retained.fileURL)
        var games = [missing, retained]

        XCTAssertThrowsError(try GameLibraryDeletion.delete(at: missing.fileURL, from: &games, fileURL: \.fileURL))

        XCTAssertEqual(games, [missing, retained])
        XCTAssertEqual(try Data(contentsOf: retained.fileURL), Data([2]))
    }

    @MainActor func testDeletingFinalGameLeavesEmptyLibrary() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let game = Game(fileURL: directory.appendingPathComponent("only.nsp"), titleID: "only")
        try Data([1]).write(to: game.fileURL)
        var games = [game]

        try GameLibraryDeletion.delete(at: game.fileURL, from: &games, fileURL: \.fileURL)

        XCTAssertTrue(games.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.fileURL.path))
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloNX-game-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
