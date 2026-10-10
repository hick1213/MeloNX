import XCTest
@testable import MeloNXJITCore

func pairingFixture(_ changes: [String: Any] = [:], format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
    var fields: [String: Any] = ["identifier": "test-host", "public_key": Data(repeating: 1, count: 32), "private_key": Data(repeating: 2, count: 32)]
    fields.merge(changes) { _, new in new }
    return try PropertyListSerialization.data(fromPropertyList: fields, format: format, options: 0)
}

final class JITMessageTests: XCTestCase {
    func testPairingRejectsMalformedKeyFieldsAndOversizedInput() throws {
        XCTAssertThrowsError(try PairingRecord(validating: Data("not a plist".utf8)))
        XCTAssertThrowsError(try PairingRecord(validating: pairingFixture(["private_key": Data(repeating: 0, count: 31)])))
        XCTAssertThrowsError(try PairingRecord(validating: pairingFixture(["public_key": "wrong type"])))
        XCTAssertThrowsError(try PairingRecord(validating: pairingFixture(["identifier": "   "])))
        XCTAssertThrowsError(try PairingRecord(validating: Data(repeating: 0, count: 1_048_577)))
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let data = try pairingFixture(format: format)
            XCTAssertEqual(try PairingRecord(validating: data).data, data)
        }
    }

    func testRequestRejectsWrongVersionPIDAndUnexpectedResetPayload() throws {
        let data = try pairingFixture()
        XCTAssertThrowsError(try JITRequest(version: 2, operationID: UUID(), operation: .enable, targetPID: 123, pairingData: data).validated())
        XCTAssertThrowsError(try JITRequest(version: 1, operationID: UUID(), operation: .enable, targetPID: 0, pairingData: data).validated())
        XCTAssertThrowsError(try JITRequest(version: 1, operationID: UUID(), operation: .enable, targetPID: 123, pairingData: nil).validated())
        XCTAssertThrowsError(try JITRequest(version: 1, operationID: UUID(), operation: .prepare, targetPID: 123, pairingData: data).validated())
        XCTAssertThrowsError(try JITRequest(version: 1, operationID: UUID(), operation: .resetDDI, targetPID: nil, pairingData: data).validated())
        XCTAssertThrowsError(try JITRequest(version: 1, operationID: UUID(), operation: .enable, targetPID: 123, pairingData: Data(repeating: 0, count: 1_048_577)).validated())
        _ = try JITRequest(version: 1, operationID: UUID(), operation: .enable, targetPID: 123, pairingData: data).validated()
        _ = try JITRequest(version: 1, operationID: UUID(), operation: .prepare, targetPID: nil, pairingData: data).validated()
        _ = try JITRequest(version: 1, operationID: UUID(), operation: .resetDDI, targetPID: nil, pairingData: nil).validated()
    }

    func testReplyRejectsWrongOperationTruncationAndOversizeAndPreservesUnknownTXM() throws {
        let id = UUID()
        let reply = JITReply(version: 1, operationID: id, success: true, message: "ready", txmPresent: nil)
        let bytes = try JSONEncoder().encode(reply)
        XCTAssertNil(try JITReply.decode(bytes, expectedID: id).txmPresent)
        XCTAssertThrowsError(try JITReply.decode(bytes, expectedID: UUID()))
        XCTAssertThrowsError(try JITReply.decode(Data(bytes.prefix(5)), expectedID: id))
        XCTAssertThrowsError(try JITReply.decode(Data(repeating: 0, count: 65_537), expectedID: id))
        let wrong = JITReply(version: 2, operationID: id, success: true, message: "ready", txmPresent: false)
        XCTAssertThrowsError(try JITReply.decode(JSONEncoder().encode(wrong), expectedID: id))
    }
}
