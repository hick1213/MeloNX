import XCTest
@testable import MeloNXSaveSyncCore

enum SnapshotFixture {
    static let user = "00000000000000000000000000000001"
    static let otherUser = "00000000000000000000000000000002"
    static func version(_ id: UUID = UUID(), parent: UUID? = nil, user: String = user,
                        availability: SnapshotAvailability = .verified, time: String = "2026-01-01T00:00:00Z", titleID: UInt64 = 0x100) -> VisibleSnapshot {
        let key = SaveSlotKey(programID: titleID, userID: user, type: .account, index: 0)
        let path = SnapshotPaths.recordManifest(key: key, generation: id)
        let reference = SaveRecordReference(key: key, manifestRelativePath: path,
            manifestSha256: String(repeating: "a", count: 64), totalBytes: 0)
        return VisibleSnapshot(snapshot: SaveSnapshot(schemaVersion: 1, generation: id, parent: parent,
            titleID: titleID, ownerUserID: user, createdUTC: time, installationID: UUID(), totalBytes: 0, records: [reference]),
            availability: availability)
    }
}

final class SnapshotVersionGraphTests: XCTestCase {
    func testVersionsOfDifferentGamesCannotShareGraph() throws {
        XCTAssertThrowsError(try SnapshotVersionGraph([SnapshotFixture.version(), SnapshotFixture.version(titleID: 0x200)]))
    }
    func testIncompleteVisibleChildBlocksCompleteParent() throws {
        let parent = SnapshotFixture.version()
        let child = SnapshotFixture.version(parent: parent.snapshot.generation, availability: .pending)
        XCTAssertEqual(try SnapshotVersionGraph([parent, child]).select(ownerUserID: SnapshotFixture.user), .pending([child.snapshot.generation]))
    }
    func testTwoDeviceBranchesRequireExplicitChoice() throws {
        let parent = SnapshotFixture.version()
        let a = SnapshotFixture.version(parent: parent.snapshot.generation)
        let b = SnapshotFixture.version(parent: parent.snapshot.generation)
        XCTAssertEqual(try SnapshotVersionGraph([parent, a, b]).select(ownerUserID: SnapshotFixture.user), .conflict([a.snapshot.generation, b.snapshot.generation]))
    }
    func testIndependentUploadCannotSilentlyReplaceExistingBranch() throws {
        let a = SnapshotFixture.version(), b = SnapshotFixture.version()
        XCTAssertEqual(try SnapshotVersionGraph([a, b]).select(ownerUserID: SnapshotFixture.user), .conflict([a.snapshot.generation, b.snapshot.generation]))
    }
    func testClockRollbackDoesNotPreferParent() throws {
        let parent = SnapshotFixture.version(time: "2026-12-31T00:00:00Z")
        let child = SnapshotFixture.version(parent: parent.snapshot.generation, time: "2026-01-01T00:00:00Z")
        XCTAssertEqual(try SnapshotVersionGraph([parent, child]).select(ownerUserID: SnapshotFixture.user), .ready(child.snapshot.generation))
    }
    func testUnreadableVisibleGenerationBlocksOlderCompleteVersion() throws {
        let old = SnapshotFixture.version(), unreadable = UUID()
        XCTAssertEqual(try SnapshotVersionGraph([old], unreadableGenerations: [unreadable]).select(ownerUserID: SnapshotFixture.user), .pending([unreadable]))
    }
    func testUnknownParentDoesNotEraseKnownIndependentBranch() throws {
        let a = SnapshotFixture.version(), b = SnapshotFixture.version(parent: UUID())
        XCTAssertEqual(try SnapshotVersionGraph([a, b]).select(ownerUserID: SnapshotFixture.user), .conflict([a.snapshot.generation, b.snapshot.generation]))
    }
    func testCycleDuplicateGenerationAndCrossUserParentAreRejected() throws {
        let a = UUID(), b = UUID()
        XCTAssertThrowsError(try SnapshotVersionGraph([SnapshotFixture.version(a, parent: b), SnapshotFixture.version(b, parent: a)]))
        XCTAssertThrowsError(try SnapshotVersionGraph([SnapshotFixture.version(a), SnapshotFixture.version(a)]))
        XCTAssertThrowsError(try SnapshotVersionGraph([SnapshotFixture.version(a), SnapshotFixture.version(parent: a, user: SnapshotFixture.otherUser)]))
    }
    func testSelectingLocalUserNeverSelectsOtherCloudUserImplicitly() throws {
        let other = SnapshotFixture.version(user: SnapshotFixture.otherUser)
        XCTAssertEqual(try SnapshotVersionGraph([other]).select(ownerUserID: SnapshotFixture.user), .none)
    }
}
