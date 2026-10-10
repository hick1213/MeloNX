import XCTest
@testable import MeloNXJITCore

@MainActor private final class MemoryCredentialBackend: PairingCredentialBackend {
    var data: Data?
    var shouldFailWrite = false
    init(_ data: Data?) { self.data = data }
    func read() throws -> Data? { data }
    func write(_ value: Data) throws {
        if shouldFailWrite { throw NSError(domain: "fixture", code: 1) }
        data = value
    }
}

final class PairingImportTests: XCTestCase {
    @MainActor func testInvalidAndFailedReplacementPreserveValidCredential() throws {
        let old = try pairingFixture(["identifier": "old-host"])
        let backend = MemoryCredentialBackend(old)
        let store = PairingImportStore(backend: backend)
        XCTAssertThrowsError(try store.replace(with: Data("broken".utf8)))
        XCTAssertEqual(try store.load()?.data, old)
        backend.shouldFailWrite = true
        XCTAssertThrowsError(try store.replace(with: pairingFixture(["identifier": "new-host"])))
        XCTAssertEqual(try store.load()?.data, old)
        backend.shouldFailWrite = false
        let new = try pairingFixture(["identifier": "new-host"])
        try store.replace(with: new)
        XCTAssertEqual(try store.load()?.data, new)
    }
}
