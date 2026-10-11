import XCTest
import MeloNXOperationCore
@testable import MeloNXSaveSyncCore

let fixtureUID = "00000000000000000000000000000001"
let foreignFixtureUID = "00000000000000000000000000000002"

func writeSaveFixture(root: URL, generation: UUID, owner: String, parent: UUID? = nil, installation: UUID = UUID()) throws -> SaveSnapshot {
    let keys = [SaveSlotKey(programID: 0x100, userID: owner, type: .account, index: 0),
                SaveSlotKey(programID: 0x100, userID: "shared", type: .device, index: 0)]
    var references: [SaveRecordReference] = []
    for key in keys {
        let relative = SnapshotPaths.recordManifest(key: key, generation: generation)
        let path = root.appendingPathComponent(relative), payload = path.deletingLastPathComponent().appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let contents = key.type == .account ? Data([1, 2, 3]) : Data()
        let files = key.type == .account ? [SaveFileEntry(path: "progress.bin", length: 3, sha256: SnapshotLocalVerifier.digest(contents))] : []
        if !contents.isEmpty { try contents.write(to: payload.appendingPathComponent("progress.bin")) }
        let record = SaveRecordManifest(schemaVersion: 1, generation: generation, key: key, files: files, emptyDirectories: ["empty"])
        let data = try SnapshotValidation.encode(record); try data.write(to: path)
        references.append(SaveRecordReference(key: key, manifestRelativePath: relative, manifestSha256: SnapshotLocalVerifier.digest(data), totalBytes: Int64(contents.count)))
    }
    let snapshot = SaveSnapshot(schemaVersion: 1, generation: generation, parent: parent, titleID: 0x100, ownerUserID: owner,
        createdUTC: "2026-01-01T00:00:00Z", installationID: installation, totalBytes: 3, records: references)
    let game = root.appendingPathComponent(SnapshotPaths.gameManifest(titleID: snapshot.titleID, generation: generation))
    try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
    try SnapshotValidation.encode(snapshot).write(to: game)
    return snapshot
}

actor HeldSaveWorker: SaveNativeService {
    var user = fixtureUID
    var describeCount = 0, exportCount = 0, restoreCount = 0, ackCount = 0
    var stopRequested = false
    var ended = true
    var holdRestore = false
    var onRestore: (@Sendable () -> Void)?
    private var restoreContinuation: CheckedContinuation<SaveNativeResult, Never>?
    private var completed: SaveNativeResult?
    func configureRestore(hold: Bool, onEntered: @escaping @Sendable () -> Void) { holdRestore = hold; onRestore = onEntered }
    func describe(_ game: SaveGameSelection) async throws -> SaveNativeSelection {
        describeCount += 1
        return SaveNativeSelection(id: UUID(), titleID: game.titleID, localUserID: user,
            keys: [SaveSlotKey(programID: game.titleID, userID: user, type: .account, index: 0)], canCreateMissing: true)
    }
    func export(_ selection: SaveNativeSelection, identity: SaveExportIdentity, into root: URL) async throws -> NativeExportResult {
        exportCount += 1
        let manifest = try writeSaveFixture(root: root, generation: identity.generation, owner: identity.cloudUserID, parent: identity.parent, installation: identity.installationID)
        return NativeExportResult(localRoot: root, manifest: manifest)
    }
    func restore(_ selection: SaveNativeSelection, snapshotRoot: URL, bindingIntentFile: URL) async throws -> SaveNativeResult {
        restoreCount += 1; ended = false
        let intent = try JSONDecoder().decode(SaveBindingIntent.self, from: Data(contentsOf: bindingIntentFile))
        completed = SaveNativeResult(status: .completed, completedBindings: [SaveCompletedBinding(transactionID: UUID(), intent: intent)])
        if holdRestore {
            return await withCheckedContinuation { continuation in
                restoreContinuation = continuation; onRestore?()
            }
        }
        ended = true; onRestore?(); return completed!
    }
    func finish(status: SaveNativeStatus) {
        ended = true
        let result = status == .completed ? completed! : SaveNativeResult(status: status, blockedGames: status == .recoveryRequired ? [0x100] : [])
        restoreContinuation?.resume(returning: result); restoreContinuation = nil
    }
    func recover() async throws -> SaveNativeResult { SaveNativeResult(status: .completed) }
    func acknowledgeBinding(transactionID: UUID) async throws { ackCount += 1 }
    func requestSafeStop() async { stopRequested = true }
    func confirmEnded() async -> Bool { ended }
}

actor ControlledCloudStore: CloudSaveStore {
    var current = CloudIdentity(localAccountKey: UUID(), container: "iCloud.test")
    var listing = CloudListing(versions: [], unreadableGenerations: [])
    var queued = false, holdUpload = false
    var onUploadWait: (@Sendable () -> Void)?
    var published: SaveSnapshot?
    var publishCount = 0
    private var uploadContinuation: CheckedContinuation<Void, Error>?
    func setListing(_ value: CloudListing) { listing = value }
    func setQueued(_ value: Bool) { queued = value }
    func switchIdentity() { current = CloudIdentity(localAccountKey: UUID(), container: current.container) }
    func holdUploads(onEntered: @escaping @Sendable () -> Void) { holdUpload = true; onUploadWait = onEntered }
    func identity() async throws -> CloudIdentity { current }
    private func check(_ captured: CloudIdentity) throws { guard captured == current else { throw SaveSyncError.identityMismatch } }
    func list(titleID: UInt64, identity: CloudIdentity) async throws -> CloudListing { try check(identity); return listing }
    func publish(localRoot: URL, snapshot: SaveSnapshot, identity: CloudIdentity) async throws {
        try check(identity); _ = try SnapshotLocalVerifier.verify(root: localRoot, snapshot: snapshot)
        published = snapshot; publishCount += 1
    }
    func waitUploaded(snapshot: SaveSnapshot, identity: CloudIdentity) async throws {
        try check(identity)
        if queued { throw SaveSyncError.queued }
        if holdUpload { try await withCheckedThrowingContinuation { continuation in uploadContinuation = continuation; onUploadWait?() } }
        try check(identity)
    }
    func confirmAllFilesUploaded() { holdUpload = false; uploadContinuation?.resume(); uploadContinuation = nil }
    func download(snapshot: SaveSnapshot, into root: URL, identity: CloudIdentity) async throws {
        try check(identity)
        _ = try writeSaveFixture(root: root, generation: snapshot.generation, owner: snapshot.ownerUserID, parent: snapshot.parent, installation: snapshot.installationID)
    }
}

@MainActor final class SaveEngineFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("save-engine-\(UUID().uuidString)")
    let gate = LocalOperationGate()
    let worker = HeldSaveWorker()
    let cloud = ControlledCloudStore()
    let game = SaveGameSelection(titleID: 0x100, gamePath: "/synthetic-fixture.nsp")
    let bindings: SaveUserBindings
    let engine: SaveSyncEngine
    init(write: (@Sendable (URL, Data) throws -> Void)? = nil) {
        let bindingRoot = root
        bindings = write.map { SaveUserBindings(root: bindingRoot, write: $0) } ?? SaveUserBindings(root: bindingRoot)
        engine = SaveSyncEngine(gate: gate, native: worker, cloud: cloud, bindings: bindings, ownedRoot: root, installationID: UUID())
    }
    func installSnapshot(owner: String = fixtureUID) async throws -> SaveSnapshot {
        let temporary = root.appendingPathComponent("cloud-fixture")
        let snapshot = try writeSaveFixture(root: temporary, generation: UUID(), owner: owner)
        await cloud.setListing(CloudListing(versions: [VisibleSnapshot(snapshot: snapshot, availability: .verified)], unreadableGenerations: []))
        return snapshot
    }
    func key() async -> SaveBindingKey {
        let identity = try! await cloud.identity()
        return SaveBindingKey(localCloudAccountUUID: identity.localAccountKey, container: identity.container, titleID: game.titleID, localUID: fixtureUID)
    }
    func dispose() { try? FileManager.default.removeItem(at: root) }
}
