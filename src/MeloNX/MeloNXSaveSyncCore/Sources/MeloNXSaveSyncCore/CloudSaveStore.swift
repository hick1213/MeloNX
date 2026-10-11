import Foundation

public struct CloudIdentity: Hashable, Sendable {
    public let localAccountKey: UUID
    public let container: String
    public init(localAccountKey: UUID, container: String) { self.localAccountKey = localAccountKey; self.container = container }
}
public protocol CloudSaveStore: Sendable {
    func identity() async throws -> CloudIdentity
    func list(titleID: UInt64, identity: CloudIdentity) async throws -> CloudListing
    func publish(localRoot: URL, snapshot: SaveSnapshot, identity: CloudIdentity) async throws
    func waitUploaded(snapshot: SaveSnapshot, identity: CloudIdentity) async throws
    func download(snapshot: SaveSnapshot, into: URL, identity: CloudIdentity) async throws
}
public enum CloudTransferDirection: Sendable { case upload, download }
public struct CloudFileState: Sendable {
    public let uploaded: Bool
    public let downloaded: Bool
    public let conflicted: Bool
    public let error: SaveSyncError?
    public init(uploaded: Bool, downloaded: Bool, conflicted: Bool = false, error: SaveSyncError? = nil) {
        self.uploaded = uploaded; self.downloaded = downloaded; self.conflicted = conflicted; self.error = error
    }
}
public struct CloudTransferConfirmation: Sendable {
    public let identity: CloudIdentity
    public let requiredFiles: Set<String>
    public init(identity: CloudIdentity, requiredFiles: Set<String>) { self.identity = identity; self.requiredFiles = requiredFiles }
    public func confirm(current: CloudIdentity, states: [String: CloudFileState], direction: CloudTransferDirection) throws -> Bool {
        guard current == identity else { throw SaveSyncError.identityMismatch }
        guard !requiredFiles.isEmpty else { throw SaveSyncError.incompleteSnapshot }
        var complete = true
        for file in requiredFiles {
            guard let state = states[file] else { complete = false; continue }
            if state.conflicted { throw SaveSyncError.conflict }
            if let error = state.error { throw error }
            if direction == .upload ? !state.uploaded : !state.downloaded { complete = false }
        }
        return complete
    }
}
