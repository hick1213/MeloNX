import XCTest
@testable import MeloNXJITCore

final class HelperTerminalTests: XCTestCase {
    func testCancellationCallbackAndLateSuccessDeliverOnlyOnceButDoNotProveTeardown() throws {
        let id = UUID()
        var terminal = JITHelperTerminal(operationID: id)
        XCTAssertTrue(terminal.fail(.cancelled))
        let late = JITReply(operationID: id, success: true, message: "late", txmPresent: nil)
        XCTAssertFalse(try terminal.receive(JSONEncoder().encode(late)))
        XCTAssertFalse(terminal.canRelease(workerEnded: false, traced: false))
        XCTAssertFalse(terminal.canRelease(workerEnded: true, traced: nil))
        XCTAssertFalse(terminal.canRelease(workerEnded: true, traced: true))
        XCTAssertTrue(terminal.canRelease(workerEnded: true, traced: false))
    }
    func testInvalidResponseBecomesTerminalFailure() throws {
        let id = UUID()
        for payload in [Data("bad".utf8), Data(repeating: 0, count: 65_537),
                        try JSONEncoder().encode(JITReply(operationID: UUID(), success: true, message: "wrong", txmPresent: nil))] {
            var terminal = JITHelperTerminal(operationID: id)
            XCTAssertThrowsError(try terminal.receive(payload))
            XCTAssertTrue(terminal.hasResult)
        }
    }
    func testInstalledRenamedHelperIdentifierAndMissingHelper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(JITHelperLocation.identifier(in: directory))
        let helper = directory.appendingPathComponent("MeloNXJITHelper.appex")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.renamed.host.JITHelper", "CFBundlePackageType": "XPC!"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: helper.appendingPathComponent("Info.plist"))
        XCTAssertEqual(JITHelperLocation.identifier(in: directory), "com.renamed.host.JITHelper")
    }
}

extension HelperTerminalTests {
    func testOwnedCancellationRequiresMatchingHelperCapability() {
        XCTAssertFalse(JITHelperCapability(info: [:]).hasOwnedCancellation)
        XCTAssertFalse(JITHelperCapability(info: ["MeloNXJITCancellationVersion": 1]).hasOwnedCancellation)
        XCTAssertTrue(JITHelperCapability(info: ["MeloNXJITCancellationVersion": 2]).hasOwnedCancellation)
        let old = UUID(), retry = UUID()
        XCTAssertNotEqual(JITCancellationSignal.name(for: old), JITCancellationSignal.name(for: retry))
    }
}
