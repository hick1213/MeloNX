import Foundation
import MeloNXOperationCore

@MainActor public final class SaveRecoveryBarrier {
    private let gate: LocalOperationGate
    private var running = false
    private var previousBlocks: Set<UInt64> = []
    public private(set) var ready = false
    public init(gate: LocalOperationGate) { self.gate = gate; gate.setStartupReady(false) }
    public func run(_ recover: () async throws -> Set<UInt64>) async -> Bool {
        guard !running else { return false }
        running = true; ready = false; gate.setStartupReady(false)
        defer { running = false }
        do {
            let lease = try gate.acquire(.recovery, gameID: nil)
            do {
                let blocked = try await recover()
                gate.block(gameIDs: blocked)
                for id in previousBlocks.subtracting(blocked) { gate.unblock(gameID: id) }
                previousBlocks = blocked
                try lease.finish(workerHasEnded: true)
                ready = true; gate.setStartupReady(true)
                return true
            } catch {
                // The recovery adapter returns/throws only after its real worker ends.
                try lease.finish(workerHasEnded: true)
                throw error
            }
        } catch { return false }
    }
}
