import Foundation

extension SaveSyncError {
    public static func fromNative(code: String?) -> SaveSyncError {
        switch code {
        case "noSave": return .noSave
        case "busy": return .busy
        case "identityMismatch": return .identityMismatch
        case "malformedSnapshot", "invalid_request", "invalid_result": return .malformedSnapshot
        case "rollbackRequired": return .rollbackRequired
        case "insufficientSpace": return .insufficientSpace
        default: return .restoreFailed
        }
    }
}
