import Foundation
import MeloNXOperationCore

@MainActor enum LocalOperations {
    static let shared = LocalOperationGate()
    static func beginImport(gameID: UInt64? = nil) -> LocalOperationLease? {
        do { return try shared.acquire(.packageImport, gameID: gameID) }
        catch { AppAlerts.showSyncAlert(title: "Operation unavailable", message: error.localizedDescription); return nil }
    }
}
