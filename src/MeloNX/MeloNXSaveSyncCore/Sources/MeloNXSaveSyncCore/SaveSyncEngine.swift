import Foundation
import MeloNXOperationCore

public enum SaveSyncPhase: Equatable, Sendable {
    case idle, exporting, publishing, queued, uploaded, listing, downloading, validating
    case awaitingRestoreConfirmation, restoring, finishing, recoveryRequired, failed, cancelled
}

@MainActor public final class SaveSyncEngine {
    private struct Prepared {
        let game: SaveGameSelection
        let identity: CloudIdentity
        let selection: SaveNativeSelection
        let key: SaveBindingKey
        let binding: SaveBinding?
        let listing: CloudListing
    }
    private let gate: LocalOperationGate
    private let native: any SaveNativeService
    private let cloud: any CloudSaveStore
    private let bindings: SaveUserBindings
    private let ownedRoot: URL
    private let installationID: UUID
    private var prepared: Prepared?
    private var lease: LocalOperationLease?
    private var operation: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var nativeRunning = false
    private var cancelRequested = false
    private var mutationPossible = false
    private var currentGame: UInt64?
    private var resumableUpload = false
    public var onChange: (() -> Void)?
    public private(set) var phase: SaveSyncPhase = .idle { didSet { onChange?() } }
    public private(set) var error: SaveSyncError?
    public private(set) var versions: [VisibleSnapshot] = []
    public private(set) var defaultGeneration: UUID?
    public private(set) var pendingGenerations: Set<UUID> = []
    public private(set) var blockedGames: Set<UInt64> = []
    public private(set) var restoredGeneration: UUID?
    public private(set) var cleanupPending = false
    public var canStart: Bool { operation == nil && lease == nil && gate.canAcquire(.saveExport, gameID: nil) }
    public var isActive: Bool { operation != nil || lease != nil }
    public func resetSelection() {
        guard operation == nil, lease == nil else { return }
        prepared = nil; versions = []; defaultGeneration = nil; pendingGenerations = []; restoredGeneration = nil; error = nil
        phase = blockedGames.isEmpty ? .idle : .recoveryRequired
    }
    public var preparedGameID: UInt64? { prepared?.game.titleID }
    public var localUserID: String? { prepared?.selection.localUserID }
    public var expectedCloudUserID: String? { prepared.map { $0.binding?.cloudUID ?? $0.selection.localUserID } }
    public init(gate: LocalOperationGate, native: any SaveNativeService, cloud: any CloudSaveStore,
                bindings: SaveUserBindings, ownedRoot: URL, installationID: UUID) {
        self.gate = gate; self.native = native; self.cloud = cloud; self.bindings = bindings
        self.ownedRoot = ownedRoot; self.installationID = installationID
    }
    public func markRecoveryRequired(gameIDs: Set<UInt64>) {
        blockedGames.formUnion(gameIDs); gate.block(gameIDs: gameIDs)
        if !blockedGames.isEmpty { phase = .recoveryRequired }
    }
    public func cancel() {
        guard let operation else { return }
        cancelRequested = true; operation.cancel()
        if nativeRunning {
            phase = .finishing
            if stopTask == nil { stopTask = Task { await native.requestSafeStop() } }
        }
    }
    private func invoke<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        nativeRunning = true
        do {
            let value = try await body()
            await stopTask?.value; stopTask = nil; nativeRunning = false
            guard await native.confirmEnded() else { throw LocalOperationError.workerActive }
            return value
        } catch {
            await stopTask?.value; stopTask = nil; nativeRunning = false
            throw error
        }
    }
    private func releaseLease() async throws {
        guard let lease else { return }
        try lease.finish(workerHasEnded: await native.confirmEnded())
        self.lease = nil
    }
    private func start(gameID: UInt64?, _ body: @escaping @MainActor () async throws -> Void) async {
        guard operation == nil, lease == nil else { return }
        currentGame = gameID; cancelRequested = false; mutationPossible = false; resumableUpload = false
        error = nil; restoredGeneration = nil; cleanupPending = false
        let task = Task {
            do { try await body() }
            catch {
                if self.mutationPossible, let gameID = self.currentGame {
                    self.markRecoveryRequired(gameIDs: [gameID]); self.error = .rollbackRequired
                } else if error is CancellationError || self.cancelRequested {
                    self.phase = .cancelled
                } else {
                    if let typed = error as? SaveSyncError { self.error = typed }
                    else if case LocalOperationError.recoveryRequired = error { self.error = .rollbackRequired }
                    else { self.error = error is LocalOperationError ? .busy : .restoreFailed }
                    self.phase = self.error == .queued && self.resumableUpload ? .queued : .failed
                }
            }
            do { try await self.releaseLease() }
            catch { self.error = .rollbackRequired; self.phase = .finishing }
        }
        operation = task
        onChange?()
        await task.value
        operation = nil; onChange?()
    }
    public func upload(_ game: SaveGameSelection) async {
        await start(gameID: game.titleID) {
            self.prepared = nil; self.versions = []; self.defaultGeneration = nil; self.phase = .exporting
            self.lease = try self.gate.acquire(.saveExport, gameID: game.titleID)
            let identity = try await self.cloud.identity()
            let current = try await self.invoke { try await self.native.describe(game) }
            try Task.checkCancellation()
            let key = SaveBindingKey(localCloudAccountUUID: identity.localAccountKey, container: identity.container, titleID: game.titleID, localUID: current.localUserID)
            let binding = try self.bindings.read(key: key)
            let queued = try await SaveQueuedUpload.loadAsync(ownedRoot: self.ownedRoot, key: key, binding: binding)
            let snapshot: SaveSnapshot
            if let queued {
                snapshot = queued.snapshot
                try await self.releaseLease()
                self.resumableUpload = true
            } else {
                guard !current.keys.isEmpty else { throw SaveSyncError.noSave }
                let generation = UUID()
                let export = SaveExportIdentity(cloudUserID: binding?.cloudUID ?? current.localUserID, parent: binding?.lastGeneration,
                    generation: generation, installationID: self.installationID, createdUTC: ISO8601DateFormatter().string(from: Date()))
                let root = SaveQueuedUpload.root(self.ownedRoot, generation: generation)
                let result = try await self.invoke { try await self.native.export(current, identity: export, into: root) }
                guard result.manifest.titleID == game.titleID, result.manifest.generation == generation,
                      result.manifest.ownerUserID == export.cloudUserID, result.manifest.parent == export.parent else { throw SaveSyncError.malformedSnapshot }
                _ = try await SnapshotLocalVerifier.verifyAsync(root: root, snapshot: result.manifest)
                try Task.checkCancellation()
                try await self.releaseLease()
                self.phase = .publishing
                try await self.cloud.publish(localRoot: root, snapshot: result.manifest, identity: identity)
                let marker = SaveQueuedUpload(version: 1, key: key, snapshot: result.manifest)
                try marker.persist(ownedRoot: self.ownedRoot)
                snapshot = result.manifest; self.resumableUpload = true
            }
            self.phase = .publishing
            try await self.cloud.waitUploaded(snapshot: snapshot, identity: identity)
            try Task.checkCancellation()
            guard try await self.cloud.identity() == identity else { throw SaveSyncError.identityMismatch }
            // Do not move a binding backwards after an independent completed restore.
            guard try self.bindings.read(key: key) == binding else { throw SaveSyncError.conflict }
            try self.bindings.recordUploaded(key: key, cloudUID: snapshot.ownerUserID, generation: snapshot.generation)
            do {
                let acknowledged = SaveQueuedUpload(version: 1, key: key, snapshot: snapshot)
                try acknowledged.acknowledge(ownedRoot: self.ownedRoot)
                try acknowledged.removeStaging(ownedRoot: self.ownedRoot)
            }
            catch { self.cleanupPending = true } // Acknowledged cloud/binding success is not undone by staging cleanup.
            self.phase = .uploaded
        }
    }
    public func prepareDownload(_ game: SaveGameSelection) async {
        await start(gameID: game.titleID) {
            self.prepared = nil; self.versions = []; self.defaultGeneration = nil; self.pendingGenerations = []
            self.phase = .listing
            self.lease = try self.gate.acquire(.saveRestore, gameID: game.titleID)
            let identity = try await self.cloud.identity()
            let current = try await self.invoke { try await self.native.describe(game) }
            try Task.checkCancellation()
            let key = SaveBindingKey(localCloudAccountUUID: identity.localAccountKey, container: identity.container, titleID: game.titleID, localUID: current.localUserID)
            let binding = try self.bindings.read(key: key)
            try await self.releaseLease()
            let listing = try await self.cloud.list(titleID: game.titleID, identity: identity)
            guard listing.versions.allSatisfy({ $0.snapshot.titleID == game.titleID }) else { throw SaveSyncError.malformedSnapshot }
            let graph = try SnapshotVersionGraph(listing.versions, unreadableGenerations: listing.unreadableGenerations)
            guard try await self.cloud.identity() == identity else { throw SaveSyncError.identityMismatch }
            try Task.checkCancellation()
            self.prepared = Prepared(game: game, identity: identity, selection: current, key: key, binding: binding, listing: listing)
            self.versions = listing.versions
            let owner = binding?.cloudUID ?? current.localUserID
            switch try graph.select(ownerUserID: owner) {
            case .ready(let generation): self.defaultGeneration = generation
            case .pending(let generations): self.pendingGenerations = generations
            case .conflict: self.error = .conflict
            case .none:
                let foreign = Set(listing.versions.map { $0.snapshot.ownerUserID })
                if foreign.count == 1, let only = foreign.first, case .ready(let generation) = try graph.select(ownerUserID: only) {
                    self.defaultGeneration = generation // UI requires explicit foreign binding confirmation.
                }
            }
            self.phase = .awaitingRestoreConfirmation
        }
    }
    public func restorePrepared(generation: UUID, allowUserBinding: Bool) async {
        guard let prepared else { error = .incompleteSnapshot; phase = .failed; return }
        await start(gameID: prepared.game.titleID) {
            guard let version = prepared.listing.versions.first(where: { $0.snapshot.generation == generation }) else { throw SaveSyncError.incompleteSnapshot }
            let snapshot = version.snapshot
            let expected = prepared.binding?.cloudUID ?? prepared.selection.localUserID
            guard snapshot.ownerUserID == expected || allowUserBinding else { throw SaveSyncError.identityMismatch }
            guard try await self.cloud.identity() == prepared.identity else { throw SaveSyncError.identityMismatch }
            self.phase = .downloading
            let root = SaveQueuedUpload.root(self.ownedRoot, generation: generation)
            try SaveLocalFiles.checkOwnedTree(root, boundary: self.ownedRoot)
            try await self.cloud.download(snapshot: snapshot, into: root, identity: prepared.identity)
            self.phase = .validating
            _ = try await SnapshotLocalVerifier.verifyAsync(root: root, snapshot: snapshot)
            try Task.checkCancellation()
            guard try await self.cloud.identity() == prepared.identity else { throw SaveSyncError.identityMismatch }
            self.lease = try self.gate.acquire(.saveRestore, gameID: prepared.game.titleID)
            let current = try await self.invoke { try await self.native.describe(prepared.game) }
            guard current.localUserID == prepared.selection.localUserID else { throw SaveSyncError.identityMismatch }
            guard try await self.cloud.identity() == prepared.identity else { throw SaveSyncError.identityMismatch }
            guard try self.bindings.read(key: prepared.key) == prepared.binding else { throw SaveSyncError.conflict }
            let intent = SaveBindingIntent(accountKey: prepared.identity.localAccountKey, container: prepared.identity.container,
                titleID: snapshot.titleID, localUID: current.localUserID, cloudUID: snapshot.ownerUserID, generation: generation)
            let file = root.appendingPathComponent("binding-intent.json")
            try SaveLocalFiles.writeDurable(file, SnapshotValidation.encode(intent))
            try Task.checkCancellation()
            self.phase = .restoring; self.mutationPossible = true
            let result = try await self.invoke { try await self.native.restore(current, snapshotRoot: root, bindingIntentFile: file) }
            switch result.status {
            case .completed:
                guard result.blockedGames.isEmpty, result.completedBindings.count == 1, result.completedBindings[0].intent == intent else { throw SaveSyncError.rollbackRequired }
                try await self.apply(result.completedBindings)
                self.mutationPossible = false; self.restoredGeneration = generation
                guard try await self.cloud.identity() == prepared.identity else { throw SaveSyncError.identityMismatch }
                self.phase = self.cancelRequested ? .cancelled : .idle
            case .safelyStopped:
                guard result.blockedGames.isEmpty else { throw SaveSyncError.rollbackRequired }
                self.mutationPossible = false; self.phase = .cancelled
            case .failed, .recoveryRequired:
                self.markRecoveryRequired(gameIDs: result.blockedGames.union([prepared.game.titleID])); self.error = .rollbackRequired
            }
        }
    }
    private func apply(_ completed: [SaveCompletedBinding]) async throws {
        for binding in completed {
            try bindings.applyCompleted(intent: binding.intent, transactionID: binding.transactionID)
            try await invoke { try await self.native.acknowledgeBinding(transactionID: binding.transactionID) }
        }
    }
    public func retryRecovery() async {
        await start(gameID: nil) {
            self.phase = .finishing
            self.lease = try self.gate.acquire(.recovery, gameID: nil)
            let result = try await self.invoke { try await self.native.recover() }
            guard result.status == .completed || result.status == .recoveryRequired && !result.blockedGames.isEmpty else { throw SaveSyncError.rollbackRequired }
            try await self.apply(result.completedBindings)
            for game in self.blockedGames.subtracting(result.blockedGames) { self.gate.unblock(gameID: game) }
            self.blockedGames = result.blockedGames
            self.gate.block(gameIDs: result.blockedGames)
            self.phase = result.blockedGames.isEmpty ? .idle : .recoveryRequired
        }
    }
}
