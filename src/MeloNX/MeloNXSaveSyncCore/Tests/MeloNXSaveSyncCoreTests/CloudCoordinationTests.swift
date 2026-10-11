import XCTest
@testable import MeloNXSaveSyncCore

final class CloudCoordinationTests: XCTestCase {
    func testCancellationWaitsForRunningLocalCopyToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-coordination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.bin")
        try Data([0]).write(to: file)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        let coordinator = CloudFileCoordinator()
        let worker = Task {
            defer { ended.signal() }
            return try await coordinator.coordinate(file, writing: true) { url in
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw SaveSyncError.restoreFailed }
                try Data([1]).write(to: url)
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        worker.cancel()
        XCTAssertEqual(ended.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        do { try await worker.value; XCTFail("Cancelled cloud operation returned success") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
    }
    func testCompletedCopyDoesNotKeepCoordinatedReaderLocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-short-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.bin")
        let coordinator = CloudFileCoordinator()
        try await coordinator.coordinate(file, writing: true) { try Data([2]).write(to: $0) }
        // Metadata/upload confirmation runs after coordinate has returned.
        let data = try await coordinator.coordinate(file, writing: false) { try Data(contentsOf: $0) }
        XCTAssertEqual(data, Data([2]))
    }
}
