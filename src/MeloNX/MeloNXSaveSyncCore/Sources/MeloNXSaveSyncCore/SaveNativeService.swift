import Foundation

public struct SaveGameSelection: Sendable {
    public let titleID: UInt64
    public let gamePath: String
    public init(titleID: UInt64, gamePath: String) { self.titleID = titleID; self.gamePath = gamePath }
}
public struct SaveNativeSelection: Sendable {
    public let id: UUID
    public let titleID: UInt64
    public let localUserID: String
    public let keys: [SaveSlotKey]
    public let canCreateMissing: Bool
    public init(id: UUID, titleID: UInt64, localUserID: String, keys: [SaveSlotKey], canCreateMissing: Bool) {
        self.id = id; self.titleID = titleID; self.localUserID = localUserID; self.keys = keys; self.canCreateMissing = canCreateMissing
    }
}
public struct SaveExportIdentity: Codable, Sendable {
    public let cloudUserID: String
    public let parent: UUID?
    public let generation: UUID
    public let installationID: UUID
    public let createdUTC: String
    public init(cloudUserID: String, parent: UUID?, generation: UUID, installationID: UUID, createdUTC: String) {
        self.cloudUserID = cloudUserID; self.parent = parent; self.generation = generation
        self.installationID = installationID; self.createdUTC = createdUTC
    }
}
public struct NativeExportResult: Sendable {
    public let localRoot: URL
    public let manifest: SaveSnapshot
    public init(localRoot: URL, manifest: SaveSnapshot) { self.localRoot = localRoot; self.manifest = manifest }
}
public enum SaveNativeStatus: Int, Sendable { case completed = 0, safelyStopped = 1, failed = 2, recoveryRequired = 3 }
public struct SaveBindingIntent: Codable, Equatable, Sendable {
    public let accountKey: UUID
    public let container: String
    // These spellings match the native private journal, which is not a cloud schema.
    public let titleId: String
    public let localUserId: String
    public let cloudUserId: String
    public let generation: UUID
    public init(accountKey: UUID, container: String, titleID: UInt64, localUID: String, cloudUID: String, generation: UUID) {
        self.accountKey = accountKey; self.container = container; titleId = String(format: "%016llx", titleID)
        localUserId = localUID; cloudUserId = cloudUID; self.generation = generation
    }
    public func validate() throws -> UInt64 {
        guard SnapshotValidation.isHex(titleId, count: 16), let title = UInt64(titleId, radix: 16), title != 0,
              !container.isEmpty, container.utf8.count <= 255,
              SnapshotValidation.isHex(localUserId, count: 32), SnapshotValidation.isHex(cloudUserId, count: 32),
              localUserId != String(repeating: "0", count: 32), cloudUserId != String(repeating: "0", count: 32) else {
            throw SaveSyncError.identityMismatch
        }
        return title
    }
}
public struct SaveCompletedBinding: Codable, Sendable {
    public let transactionID: UUID
    public let intent: SaveBindingIntent
    public init(transactionID: UUID, intent: SaveBindingIntent) { self.transactionID = transactionID; self.intent = intent }
}
public struct SaveNativeResult: Sendable {
    public let status: SaveNativeStatus
    public let completedBindings: [SaveCompletedBinding]
    public let blockedGames: Set<UInt64>
    public let errorCode: String?
    public init(status: SaveNativeStatus, completedBindings: [SaveCompletedBinding] = [], blockedGames: Set<UInt64> = [], errorCode: String? = nil) {
        self.status = status; self.completedBindings = completedBindings; self.blockedGames = blockedGames; self.errorCode = errorCode
    }
}
public protocol SaveNativeService: Sendable {
    func describe(_ game: SaveGameSelection) async throws -> SaveNativeSelection
    func export(_ selection: SaveNativeSelection, identity: SaveExportIdentity, into: URL) async throws -> NativeExportResult
    func restore(_ selection: SaveNativeSelection, snapshotRoot: URL, bindingIntentFile: URL) async throws -> SaveNativeResult
    func recover() async throws -> SaveNativeResult
    func acknowledgeBinding(transactionID: UUID) async throws
    func requestSafeStop() async
    func confirmEnded() async -> Bool
}
