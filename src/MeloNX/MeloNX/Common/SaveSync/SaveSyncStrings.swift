import Foundation
import MeloNXSaveSyncCore

extension SaveSyncError: @retroactive LocalizedError {
    nonisolated public var errorDescription: String? {
        let message: String
        switch self {
        case .noSave: message = "The current user has no save for this game. Save your progress in the game first."
        case .busy: message = "Exit the game and wait for JIT or import to finish."
        case .cloudUnavailable: message = "iCloud is unavailable. Check iCloud Drive, your account, and the app's cloud permissions."
        case .queued: message = "Upload is not complete. Reconnect and retry the previous snapshot."
        case .quota: message = "iCloud storage is full. Free some space and retry."
        case .incompleteSnapshot: message = "This save version is not fully available. Refresh or try again after downloading finishes."
        case .conflict: message = "Save branches or user bindings have changed. Choose a specific cloud version; all versions are retained."
        case .identityMismatch: message = "The iCloud account or emulator user changed. Select the game and refresh its versions again."
        case .malformedSnapshot: message = "Save verification failed. The incoming snapshot was not accepted."
        case .restoreFailed: message = "The save operation failed. Check local storage and file access."
        case .rollbackRequired: message = "Save recovery is required before the affected game can start. Retry recovery."
        case .insufficientSpace: message = "There is not enough local space for a safe snapshot and restore backup."
        }
        return NSLocalizedString(message, comment: "Manual iCloud save sync error")
    }
}
