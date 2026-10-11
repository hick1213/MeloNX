import Foundation

extension SaveSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noSave: return "当前用户还没有这个游戏的存档。请先在游戏中保存进度。"
        case .busy: return "请先退出游戏，等待 JIT、导入或存档操作结束。"
        case .cloudUnavailable: return "iCloud 不可用。请检查 iCloud Drive、账户和应用的云端权限。"
        case .queued: return "上传尚未完成。请联网后重试；会继续上传之前的快照。"
        case .quota: return "iCloud 空间不足。请腾出空间后重试上传。"
        case .incompleteSnapshot: return "这个版本尚未完整下载或校验。请稍后刷新。"
        case .conflict: return "发现多个分支或绑定已改变。请选择明确的云端版本，所有版本都会保留。"
        case .identityMismatch: return "iCloud 账户或游戏用户已改变。请重新选择游戏并刷新版本。"
        case .malformedSnapshot: return "存档快照校验失败。本机进度未被替换。"
        case .restoreFailed: return "存档操作失败。请检查本机存储和文件访问。"
        case .rollbackRequired: return "存档恢复尚未完成。请重试恢复检查，完成前不能启动受影响的游戏。"
        case .insufficientSpace: return "本机空间不足，无法安全保存快照和恢复备份。"
        }
    }
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
