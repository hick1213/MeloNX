import Foundation

public enum LocalOperationKind: Sendable {
    case launch, emulation, packageImport, saveExport, saveRestore, recovery
}
public enum LocalOperationError: Error, LocalizedError {
    case busy, recoveryRequired, startupPending, workerActive, staleLease
    public var errorDescription: String? {
        switch self {
        case .busy: return "Finish the active operation and exit the game before continuing."
        case .recoveryRequired: return "This game's interrupted save restore must be recovered first."
        case .startupPending: return "Save recovery is being checked. Please wait."
        case .workerActive: return "Waiting for the native worker to finish safely."
        case .staleLease: return "This operation has already ended."
        }
    }
}

/// Every native operation shares one owner, including a launch waiting for JIT.
/// Cancellation alone never returns ownership to the next operation.
@MainActor public final class LocalOperationGate {
    private var owner: UUID?
    private var blockedGames: Set<UInt64> = []
    private var startupReady = true
    public var busy: Bool { owner != nil }
    public var onChange: (() -> Void)?
    public init() {}
    public func setStartupReady(_ ready: Bool) { startupReady = ready; onChange?() }
    public func block(gameIDs: Set<UInt64>) { blockedGames.formUnion(gameIDs); onChange?() }
    public func unblock(gameID: UInt64) { blockedGames.remove(gameID); onChange?() }
    public func canAcquire(_ kind: LocalOperationKind, gameID: UInt64?) -> Bool {
        (try? check(kind, gameID: gameID)) != nil
    }
    private func check(_ kind: LocalOperationKind, gameID: UInt64?) throws {
        guard owner == nil else { throw LocalOperationError.busy }
        guard startupReady || kind == .recovery else { throw LocalOperationError.startupPending }
        if kind != .recovery {
            if let gameID, blockedGames.contains(gameID) { throw LocalOperationError.recoveryRequired }
            if kind == .packageImport, gameID == nil, !blockedGames.isEmpty { throw LocalOperationError.recoveryRequired }
        }
    }
    public func acquire(_ kind: LocalOperationKind, gameID: UInt64?) throws -> LocalOperationLease {
        try check(kind, gameID: gameID)
        let id = UUID(); owner = id
        let lease = LocalOperationLease(gate: self, id: id, kind: kind, gameID: gameID)
        onChange?()
        return lease
    }
    fileprivate func isCurrent(_ id: UUID) -> Bool { owner == id }
    fileprivate func finish(_ id: UUID) throws {
        guard owner == id else { throw LocalOperationError.staleLease }
        owner = nil; onChange?()
    }
}

@MainActor public final class LocalOperationLease {
    public let id: UUID
    public let kind: LocalOperationKind
    public let gameID: UInt64?
    private let gate: LocalOperationGate
    private var workers: Set<UUID> = []
    public var onWorkersEnded: (() -> Void)?
    fileprivate init(gate: LocalOperationGate, id: UUID, kind: LocalOperationKind, gameID: UInt64?) {
        self.gate = gate; self.id = id; self.kind = kind; self.gameID = gameID
    }
    public func retainWorker() throws -> LocalWorkerLease {
        guard gate.isCurrent(id) else { throw LocalOperationError.staleLease }
        let workerID = UUID(); workers.insert(workerID)
        return LocalWorkerLease(owner: self, id: workerID)
    }
    public func finish(workerHasEnded: Bool) throws {
        guard gate.isCurrent(id) else { throw LocalOperationError.staleLease }
        guard workerHasEnded, workers.isEmpty else { throw LocalOperationError.workerActive }
        try gate.finish(id)
    }
    fileprivate func finishWorker(_ workerID: UUID) throws {
        guard gate.isCurrent(id), workers.remove(workerID) != nil else { throw LocalOperationError.staleLease }
        if workers.isEmpty { onWorkersEnded?() }
    }
}

/// JIT borrows a pending game's lease; its teardown is independent of the view.
@MainActor public final class LocalWorkerLease {
    private let owner: LocalOperationLease
    private let id: UUID
    fileprivate init(owner: LocalOperationLease, id: UUID) { self.owner = owner; self.id = id }
    public func finish() throws { try owner.finishWorker(id) }
}
