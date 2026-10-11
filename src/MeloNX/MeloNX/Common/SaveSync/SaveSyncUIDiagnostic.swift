#if DEBUG
import SwiftUI
import MeloNXSaveSyncCore
import MeloNXOperationCore
import UniformTypeIdentifiers

/// This mode is only UI/lifecycle evidence. Its ports never call iCloud or open
/// the emulator's NAND; synthetic payloads use a separate disposable directory.
@MainActor enum SaveSyncUIDiagnostic {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--save-sync-ui-fixture") }
    static func fixture() throws -> (GameInfo, SaveSyncCoordinator) {
        let root = URL.documentsDirectory.appendingPathComponent("SaveSyncUIFixture/\(UUID().uuidString.lowercased())")
        try SaveLocalFiles.checkOwnedTree(root, boundary: .documentsDirectory)
        let uid = "00000000000000000000000000000001"
        let snapshot = try UIDiagnosticFiles.make(root: root.appendingPathComponent("cloud-fixture"), generation: UUID(), owner: uid)
        let cloud = UIDiagnosticCloud(snapshot: snapshot)
        let native = UIDiagnosticNative()
        let coordinator = SaveSyncCoordinator(gate: LocalOperationGate(), native: native, cloud: cloud, root: root)
        let game = GameInfo(containerFolder: root, fileType: .nsp, fileURL: root.appendingPathComponent("ui-fixture.nsp"),
            titleName: "Save Sync UI Fixture", titleId: "0000000000000100", developer: "UI fixture", version: "1")
        return (game, coordinator)
    }
}

struct SaveSyncUIDiagnosticView: View {
    @State private var fixture: (GameInfo, SaveSyncCoordinator)?
    @State private var failed = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("UI fixture — no iCloud or game-save writes").font(.caption).padding().background(.yellow.opacity(0.2))
                if let fixture { GameSaveSyncView(game: fixture.0, coordinator: fixture.1, fixtureGames: [fixture.0]) }
                else { Text(failed ? "UI fixture unavailable" : "Preparing UI fixture…") }
            }
        }
        .task { do { fixture = try SaveSyncUIDiagnostic.fixture() } catch { failed = true } }
    }
}

nonisolated private enum UIDiagnosticFiles {
    static func make(root: URL, generation: UUID, owner: String, parent: UUID? = nil, installation: UUID = UUID()) throws -> SaveSnapshot {
        let key = SaveSlotKey(programID: 0x100, userID: owner, type: .account, index: 0)
        let relative = SnapshotPaths.recordManifest(key: key, generation: generation)
        let recordPath = root.appendingPathComponent(relative), payload = recordPath.deletingLastPathComponent().appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let contents = Data([1, 2, 3]); try contents.write(to: payload.appendingPathComponent("progress.bin"))
        let record = SaveRecordManifest(schemaVersion: 1, generation: generation, key: key,
            files: [SaveFileEntry(path: "progress.bin", length: 3, sha256: SnapshotLocalVerifier.digest(contents))], emptyDirectories: ["empty"])
        let data = try SnapshotValidation.encode(record); try data.write(to: recordPath)
        let snapshot = SaveSnapshot(schemaVersion: 1, generation: generation, parent: parent, titleID: 0x100, ownerUserID: owner,
            createdUTC: "2026-10-11T00:00:00Z", installationID: installation, totalBytes: 3,
            records: [SaveRecordReference(key: key, manifestRelativePath: relative, manifestSha256: SnapshotLocalVerifier.digest(data), totalBytes: 3)])
        let game = root.appendingPathComponent(SnapshotPaths.gameManifest(titleID: 0x100, generation: generation))
        try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SnapshotValidation.encode(snapshot).write(to: game)
        return snapshot
    }
}
private actor UIDiagnosticNative: SaveNativeService {
    private var ended = true, stopped = false
    func describe(_ game: SaveGameSelection) async throws -> SaveNativeSelection {
        SaveNativeSelection(id: UUID(), titleID: 0x100, localUserID: "00000000000000000000000000000001",
            keys: [SaveSlotKey(programID: 0x100, userID: "00000000000000000000000000000001", type: .account, index: 0)], canCreateMissing: true)
    }
    func export(_ selection: SaveNativeSelection, identity: SaveExportIdentity, into root: URL) async throws -> NativeExportResult {
        NativeExportResult(localRoot: root, manifest: try UIDiagnosticFiles.make(root: root, generation: identity.generation,
            owner: identity.cloudUserID, parent: identity.parent, installation: identity.installationID))
    }
    func restore(_ selection: SaveNativeSelection, snapshotRoot: URL, bindingIntentFile: URL) async throws -> SaveNativeResult {
        let intent = try JSONDecoder().decode(SaveBindingIntent.self, from: SaveLocalFiles.readRegular(bindingIntentFile, limit: 65536))
        ended = false; stopped = false
        await withCheckedContinuation { continuation in DispatchQueue.global().asyncAfter(deadline: .now() + 6) { continuation.resume() } }
        ended = true
        return stopped ? SaveNativeResult(status: .safelyStopped) : SaveNativeResult(status: .completed,
            completedBindings: [SaveCompletedBinding(transactionID: UUID(), intent: intent)])
    }
    func recover() async throws -> SaveNativeResult { SaveNativeResult(status: .completed) }
    func acknowledgeBinding(transactionID: UUID) async throws {}
    func requestSafeStop() async { stopped = true }
    func confirmEnded() async -> Bool { ended }
}
private actor UIDiagnosticCloud: CloudSaveStore {
    private let captured = CloudIdentity(localAccountKey: UUID(), container: "UI-fixture")
    private let snapshot: SaveSnapshot
    init(snapshot: SaveSnapshot) { self.snapshot = snapshot }
    func identity() async throws -> CloudIdentity { captured }
    func list(titleID: UInt64, identity: CloudIdentity) async throws -> CloudListing {
        CloudListing(versions: [VisibleSnapshot(snapshot: snapshot, availability: .verified)], unreadableGenerations: [])
    }
    func publish(localRoot: URL, snapshot: SaveSnapshot, identity: CloudIdentity) async throws { _ = try SnapshotLocalVerifier.verify(root: localRoot, snapshot: snapshot) }
    func waitUploaded(snapshot: SaveSnapshot, identity: CloudIdentity) async throws { try await Task.sleep(nanoseconds: 1_000_000_000) }
    func download(snapshot: SaveSnapshot, into root: URL, identity: CloudIdentity) async throws {
        _ = try UIDiagnosticFiles.make(root: root, generation: snapshot.generation, owner: snapshot.ownerUserID,
            parent: snapshot.parent, installation: snapshot.installationID)
    }
}
#endif
