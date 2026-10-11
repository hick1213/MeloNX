import Foundation
import Combine
import MeloNXSaveSyncCore

@MainActor final class SaveRecoveryBootstrap: ObservableObject {
    static let shared = SaveRecoveryBootstrap()
    let native = NativeSaveWorker()
    let ownedRoot: URL
    let bindings: SaveUserBindings
    private let barrier: SaveRecoveryBarrier
    private var pending: Task<Bool, Never>?
    @Published private(set) var ready = false
    @Published private(set) var failed = false
    @Published private(set) var blockedGames: Set<UInt64> = []
    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        ownedRoot = documents.appendingPathComponent("SaveSync/v1", isDirectory: true)
        bindings = SaveUserBindings(root: ownedRoot)
        barrier = SaveRecoveryBarrier(gate: LocalOperations.shared)
    }
    func ensureReady() async -> Bool {
        if ready { return true }
        if let pending { return await pending.value }
        let task = Task { await self.performRecovery() }
        pending = task
        let result = await task.value
        pending = nil
        return result
    }
    func didRecover(blockedGames: Set<UInt64>) { self.blockedGames = blockedGames }
    func retry() async -> Bool { ready = false; return await ensureReady() }
    private func performRecovery() async -> Bool {
        failed = false
        let success = await barrier.run {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try SaveLocalFiles.checkOwnedTree(self.ownedRoot, boundary: documents)
            let result = try await self.native.recover()
            guard await self.native.confirmEnded(), result.status == .completed || result.status == .recoveryRequired else { throw SaveSyncError.restoreFailed }
            guard result.status != .recoveryRequired || !result.blockedGames.isEmpty else { throw SaveSyncError.rollbackRequired }
            self.blockedGames = result.blockedGames
            for binding in result.completedBindings {
                try self.bindings.applyCompleted(intent: binding.intent, transactionID: binding.transactionID)
                try await self.native.acknowledgeBinding(transactionID: binding.transactionID)
            }
            return result.blockedGames
        }
        ready = success; failed = !success
        return success
    }
}
