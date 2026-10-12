import Foundation
import MeloNXOperationCore

@MainActor enum LocalOperations {
    static let shared = LocalOperationGate()
    static func beginImport(gameID: UInt64? = nil, onFailure: ((String) -> Void)? = nil) -> LocalOperationLease? {
        do { return try shared.acquire(.packageImport, gameID: gameID) }
        catch {
            if let onFailure { onFailure(error.localizedDescription) }
            else { AppAlerts.showSyncAlert(title: "Operation unavailable", message: error.localizedDescription) }
            return nil
        }
    }
}
