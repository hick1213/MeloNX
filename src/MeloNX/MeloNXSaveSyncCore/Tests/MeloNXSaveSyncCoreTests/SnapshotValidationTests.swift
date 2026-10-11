import XCTest
@testable import MeloNXSaveSyncCore

final class SnapshotValidationTests: XCTestCase {
    func testRecordWithoutGenerationCannotBeVerified() throws {
        let record = SaveRecordManifest(schemaVersion: 1,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            key: SaveSlotKey(programID: 0x100, userID: SnapshotFixture.user, type: .account, index: 0),
            files: [], emptyDirectories: [])
        XCTAssertThrowsError(try SnapshotValidation.decodeRecord(SnapshotValidation.encode(record)))
    }
    func testImplicitDirectoriesCountTowardEntryBudget() throws {
        let paths = (0..<50_001).map { "dir\($0)/file" }
        XCTAssertThrowsError(try SnapshotPaths.validateEntries(files: paths, emptyDirectories: []))
    }
    func testZeroGenerationIsRejectedByBothLanguages() throws {
        let good = try SnapshotValidation.encode(SnapshotFixture.version().snapshot)
        var obj = try JSONSerialization.jsonObject(with: good) as! [String: Any]
        obj["installationID"] = "00000000-0000-0000-0000-000000000000"
        XCTAssertThrowsError(try SnapshotValidation.decodeSnapshot(JSONSerialization.data(withJSONObject: obj)))
    }
    func testBothLanguagesDecodeSameHexIDAndIndexFixture() throws {
        let url = Bundle.module.url(forResource: "snapshot", withExtension: "json", subdirectory: "Fixtures")!
        let snapshot = try SnapshotValidation.decodeSnapshot(Data(contentsOf: url))
        XCTAssertEqual(snapshot.titleID, 0x100)
        XCTAssertEqual(snapshot.records.map(\.key.type), [.account, .device])
        XCTAssertEqual(snapshot.records.map(\.key.index), [2, 0])
        XCTAssertEqual(snapshot.ownerUserID, "00000000000000000000000000000001")
        let encoded = try SnapshotValidation.encode(snapshot)
        let obj = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertEqual(obj["titleID"] as? String, "0000000000000100")
    }
    func testUnknownSchemaOversizeAndNumericIDsAreRejected() throws {
        let good = try SnapshotValidation.encode(SnapshotFixture.version().snapshot)
        var obj = try JSONSerialization.jsonObject(with: good) as! [String: Any]
        obj["schemaVersion"] = 2
        XCTAssertThrowsError(try SnapshotValidation.decodeSnapshot(JSONSerialization.data(withJSONObject: obj)))
        obj["schemaVersion"] = 1; obj["titleID"] = 256
        XCTAssertThrowsError(try SnapshotValidation.decodeSnapshot(JSONSerialization.data(withJSONObject: obj)))
        XCTAssertThrowsError(try SnapshotValidation.decodeSnapshot(Data(repeating: 32, count: 4 * 1024 * 1024 + 1)))
    }
    func testUnsafePathsAndNormalizationAliasesAreRejected() throws {
        for path in ["/escape", "../escape", "a/../b", "./a", "a//b", "a\\b", "a\0b", String(repeating: "x", count: 1025)] {
            XCTAssertThrowsError(try SnapshotPaths.validate(path), path)
        }
        XCTAssertThrowsError(try SnapshotPaths.validateEntries(files: ["Save", "save"], emptyDirectories: []))
        XCTAssertThrowsError(try SnapshotPaths.validateEntries(files: ["é", "e\u{301}"], emptyDirectories: []))
        XCTAssertThrowsError(try SnapshotPaths.validateEntries(files: ["file", "file/child"], emptyDirectories: []))
        XCTAssertThrowsError(try SnapshotPaths.validateEntries(files: ["folder/file"], emptyDirectories: ["folder"]))
        XCTAssertNoThrow(try SnapshotPaths.validateEntries(files: ["folder/save.bin"], emptyDirectories: ["empty/sub"]))
    }
    func testOverflowDuplicateRecordsAndWrongRecordPathCannotReachRestore() throws {
        let good = SnapshotFixture.version().snapshot, key = good.records[0].key
        let bad = SaveRecordReference(key: key, manifestRelativePath: "other/manifest.json", manifestSha256: String(repeating: "a", count: 64), totalBytes: 0)
        XCTAssertThrowsError(try SnapshotValidation.validate(SaveSnapshot(schemaVersion: 1, generation: good.generation, parent: nil,
            titleID: good.titleID, ownerUserID: good.ownerUserID, createdUTC: good.createdUTC, installationID: good.installationID,
            totalBytes: 0, records: [bad])))
        XCTAssertThrowsError(try SnapshotValidation.validate(SaveSnapshot(schemaVersion: 1, generation: good.generation, parent: nil,
            titleID: good.titleID, ownerUserID: good.ownerUserID, createdUTC: good.createdUTC, installationID: good.installationID,
            totalBytes: 0, records: [good.records[0], good.records[0]])))
        let device = SaveSlotKey(programID: good.titleID, userID: "shared", type: .device, index: 0)
        let refs = [key, device].map { SaveRecordReference(key: $0, manifestRelativePath: SnapshotPaths.recordManifest(key: $0, generation: good.generation), manifestSha256: String(repeating: "a", count: 64), totalBytes: Int64.max) }
        XCTAssertThrowsError(try SnapshotValidation.validate(SaveSnapshot(schemaVersion: 1, generation: good.generation, parent: nil,
            titleID: good.titleID, ownerUserID: good.ownerUserID, createdUTC: good.createdUTC, installationID: good.installationID,
            totalBytes: Int64.max, records: refs)))
    }
}
