import XCTest
@testable import MeloNXImportCore

final class NSZAddonStoreTests: XCTestCase {
    func testAlreadyCommittedUpdateRetainsFilesAndExistingSelectedConfig() throws {
        let f = try Fixture(kind: 1); defer { f.remove() }
        let json = f.config.appendingPathComponent("updates.json")
        let oldPath = "updates/0000000000000100/game.nsp"
        let old: [String: Any] = ["paths": [oldPath], "selected": oldPath, "extra": "preserve"]
        try JSONSerialization.data(withJSONObject: old).write(to: json)
        let store = NSZAddonStore(documents: f.root)
        try store.registerUpdate(f.file, applicationID: 0x100)
        try store.registerUpdate(f.file, applicationID: 0x100)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as! [String: Any]
        XCTAssertEqual((saved["paths"] as! [String]).count, 2)
        XCTAssertEqual(saved["selected"] as? String, oldPath)
        XCTAssertEqual(saved["extra"] as? String, "preserve")
        try f.assertPreserved()
    }
    func testDlcEntriesAreRegisteredWithoutCopyOrGameInfoAndIdsStayExact() throws {
        let f = try Fixture(kind: 2); defer { f.remove() }
        let entry = NSZDlcEntry(path: "/content.nca", titleID: 0xfedcba9876543210, enabled: true)
        let store = NSZAddonStore(documents: f.root)
        try store.registerDLC(f.file, applicationID: 0x100, entries: [entry])
        try store.registerDLC(f.file, applicationID: 0x100, entries: [entry])
        let data = try Data(contentsOf: f.config.appendingPathComponent("dlc.json"))
        let containers = try JSONDecoder().decode([NSZDlcContainer].self, from: data)
        XCTAssertEqual(containers.count, 1)
        XCTAssertEqual(containers[0].entries[0].titleID, 0xfedcba9876543210)
        XCTAssertEqual(containers[0].path, "dlc/0000000000000100/game (1).nsp")
        try f.assertPreserved()
    }
    func testWrongRoleIdentityAndCancelledRegistrationDoNotChangeConfig() throws {
        let f = try Fixture(kind: 1); defer { f.remove() }
        let json = f.config.appendingPathComponent("updates.json")
        let data = Data("{\"paths\":[],\"selected\":\"\"}".utf8); try data.write(to: json)
        let store = NSZAddonStore(documents: f.root)
        XCTAssertThrowsError(try store.registerUpdate(f.file, applicationID: 0x200))
        XCTAssertThrowsError(try store.registerDLC(f.file, applicationID: 0x100, entries: []))
        XCTAssertThrowsError(try store.registerUpdate(f.file, applicationID: 0x100, cancelled: true))
        XCTAssertEqual(try Data(contentsOf: json), data); try f.assertPreserved()
    }
    func testRegistrationWriteFailureKeepsCompletedFileAndPriorConfig() throws {
        let f = try Fixture(kind: 1); defer { f.remove() }
        let json = f.config.appendingPathComponent("updates.json")
        let data = Data("{\"paths\":[],\"selected\":\"\"}".utf8); try data.write(to: json)
        let store = NSZAddonStore(documents: f.root, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try store.registerUpdate(f.file, applicationID: 0x100))
        XCTAssertEqual(try Data(contentsOf: json), data); try f.assertPreserved()
    }
    private struct Fixture {
        let root: URL, config: URL, oldFile: URL, file: NSZImportedFile
        init(kind: Int) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MeloNX-Addon-\(UUID())")
            let folder = root.appendingPathComponent(kind == 1 ? "updates" : "dlc").appendingPathComponent("0000000000000100")
            config = root.appendingPathComponent("games/0000000000000100")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            oldFile = folder.appendingPathComponent("game.nsp"); try Data([1, 2]).write(to: oldFile)
            let completed = folder.appendingPathComponent("game (1).nsp"); try Data([3, 4]).write(to: completed)
            file = NSZImportedFile(operationID: UUID(), path: completed.path, kind: kind, applicationID: 0x100)
        }
        func assertPreserved() throws {
            XCTAssertEqual(try Data(contentsOf: oldFile), Data([1, 2]))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), Data([3, 4]))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
