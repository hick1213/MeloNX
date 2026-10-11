import Foundation

public struct SaveSyncPresentation: Sendable {
    public let canRetry: Bool
    public let showsVersionChoice: Bool
    public init(phase: SaveSyncPhase, error: SaveSyncError?) {
        canRetry = [.queued, .failed, .cancelled, .recoveryRequired, .awaitingRestoreConfirmation].contains(phase)
        showsVersionChoice = phase == .awaitingRestoreConfirmation && error == .conflict
    }
}
