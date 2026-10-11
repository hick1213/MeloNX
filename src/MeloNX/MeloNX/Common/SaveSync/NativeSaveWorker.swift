import Foundation
import MeloNXSaveSyncCore

nonisolated private struct SaveRequest: Encodable, Sendable {
    let version = 1
    let id = UUID()
    let operation: String
    var titleID = "0000000000000000"
    var gamePath: String? = nil
    var selectionID: UUID? = nil
    var snapshotRoot: String? = nil
    var bindingIntentFile: String? = nil
    var exportIdentity: SaveExportIdentity? = nil
    var transactionID: UUID? = nil
}
nonisolated private struct SaveSelectionWire: Decodable {
    let id: UUID
    let titleID: String
    let localUserID: String
    let keys: [SaveSlotKey]
    let canCreateMissing: Bool
    func selection() throws -> SaveNativeSelection {
        guard SnapshotValidation.isHex(titleID, count: 16), let title = UInt64(titleID, radix: 16), title != 0,
              SnapshotValidation.isHex(localUserID, count: 32), keys.count <= 64,
              keys.allSatisfy({ $0.programID == title && ($0.type == .device ? $0.userID == "shared" : $0.userID == localUserID) }),
              Set(keys).count == keys.count else { throw SaveSyncError.malformedSnapshot }
        return SaveNativeSelection(id: id, titleID: title, localUserID: localUserID, keys: keys, canCreateMissing: canCreateMissing)
    }
}
nonisolated private struct SaveResultWire: Decodable {
    let version: Int
    let id: UUID
    let status: Int
    let selection: SaveSelectionWire?
    let snapshotRoot: String?
    let snapshot: SaveSnapshot?
    let completedBindings: [SaveCompletedBinding]
    let blockedGames: [String]
    let errorCode: String?
    func result() throws -> SaveNativeResult {
        guard let status = SaveNativeStatus(rawValue: status), blockedGames.count <= 8192, completedBindings.count <= 64 else {
            throw SaveSyncError.malformedSnapshot
        }
        let games = try blockedGames.map { value -> UInt64 in
            guard SnapshotValidation.isHex(value, count: 16), let title = UInt64(value, radix: 16), title != 0 else { throw SaveSyncError.malformedSnapshot }
            return title
        }
        for binding in completedBindings { _ = try binding.intent.validate() }
        return SaveNativeResult(status: status, completedBindings: completedBindings, blockedGames: Set(games), errorCode: errorCode)
    }
}

/// One serial native worker. Cancellation only requests a safe stop. Completion
/// waits for native Run, all pointer borrowers, result copying and native free.
nonisolated final class NativeSaveWorker: SaveNativeService, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeloNX.SaveSync.Native", qos: .userInitiated)
    private let lock = NSLock()
    private var active: SaveHandleLifetime?
    private func begin() throws -> SaveHandleLifetime {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { throw SaveSyncError.busy }
        let lifetime = SaveHandleLifetime(); active = lifetime; return lifetime
    }
    private func current() -> SaveHandleLifetime? { lock.lock(); defer { lock.unlock() }; return active }
    private func end() { lock.lock(); defer { lock.unlock() }; active = nil }
    func confirmEnded() async -> Bool { current() == nil }
    func requestSafeStop() async { current()?.requestStop { save_sync_request_stop($0) } }
    private func run(_ request: SaveRequest) async throws -> SaveResultWire {
        let lifetime = try begin()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result = Result { try Self.perform(request, lifetime: lifetime) }
                // Also ends a job whose native create failed before installation.
                lifetime.finish { save_sync_free($0) }
                self.end()
                continuation.resume(with: result)
            }
        }
    }
    private static func perform(_ request: SaveRequest, lifetime: SaveHandleLifetime) throws -> SaveResultWire {
        let data = try JSONEncoder().encode(request)
        guard data.count <= 65536 else { throw SaveSyncError.malformedSnapshot }
        var creationError: UnsafeMutablePointer<CChar>?
        let handle = String(decoding: data, as: UTF8.self).withCString { save_sync_create($0, &creationError) }
        if let creationError { save_sync_string_free(creationError) }
        guard let handle else { throw SaveSyncError.restoreFailed }
        guard lifetime.install(handle, stop: { save_sync_request_stop($0) }) else { save_sync_free(handle); throw SaveSyncError.restoreFailed }
        let status = Int(save_sync_run(handle))
        let resultData = lifetime.finish { handle -> Data? in
            defer { save_sync_free(handle) }
            guard let value = save_sync_result(handle) else { return nil }
            defer { save_sync_string_free(value) }
            return Data(String(cString: value).utf8)
        } ?? nil
        guard let resultData, resultData.count <= 65536 else { throw SaveSyncError.restoreFailed }
        let result = try JSONDecoder().decode(SaveResultWire.self, from: resultData)
        guard result.version == 1, result.id == request.id, result.status == status else { throw SaveSyncError.restoreFailed }
        _ = try result.result()
        if status == 2 { throw SaveSyncError.restoreFailed }
        return result
    }
    func describe(_ game: SaveGameSelection) async throws -> SaveNativeSelection {
        var request = SaveRequest(operation: "describe")
        request.titleID = String(format: "%016llx", game.titleID); request.gamePath = game.gamePath
        let value = try await run(request)
        guard value.status == 0, let selection = value.selection else { throw SaveSyncError.restoreFailed }
        return try selection.selection()
    }
    func export(_ selection: SaveNativeSelection, identity: SaveExportIdentity, into root: URL) async throws -> NativeExportResult {
        var request = SaveRequest(operation: "export")
        request.selectionID = selection.id; request.snapshotRoot = root.path; request.exportIdentity = identity
        let value = try await run(request)
        if value.status == 1 { throw CancellationError() }
        guard value.status == 0, value.snapshotRoot == root.path, let manifest = value.snapshot,
              manifest.titleID == selection.titleID, manifest.generation == identity.generation,
              manifest.ownerUserID == identity.cloudUserID else { throw SaveSyncError.malformedSnapshot }
        try SnapshotValidation.validate(manifest)
        return NativeExportResult(localRoot: root, manifest: manifest)
    }
    func restore(_ selection: SaveNativeSelection, snapshotRoot: URL, bindingIntentFile: URL) async throws -> SaveNativeResult {
        var request = SaveRequest(operation: "restore")
        request.selectionID = selection.id; request.snapshotRoot = snapshotRoot.path; request.bindingIntentFile = bindingIntentFile.path
        return try await run(request).result()
    }
    func recover() async throws -> SaveNativeResult { try await run(SaveRequest(operation: "recover")).result() }
    func acknowledgeBinding(transactionID: UUID) async throws {
        var request = SaveRequest(operation: "ack_binding"); request.transactionID = transactionID
        guard try await run(request).status == 0 else { throw SaveSyncError.restoreFailed }
    }
}
