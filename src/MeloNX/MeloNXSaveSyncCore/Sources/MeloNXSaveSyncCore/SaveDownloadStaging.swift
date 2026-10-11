import Foundation

public enum SaveDownloadStaging {
    public static func download(destination: URL, snapshot: SaveSnapshot,
                                copy: @escaping @Sendable (URL) async throws -> Void) async throws {
        let parent = destination.deletingLastPathComponent(), ownedRoot = parent.deletingLastPathComponent()
        guard parent.lastPathComponent == "staging", destination.lastPathComponent == snapshot.generation.uuidString.lowercased() else {
            throw SaveSyncError.malformedSnapshot
        }
        try SaveLocalFiles.checkOwnedTree(destination, boundary: ownedRoot)
        if FileManager.default.fileExists(atPath: destination.path) {
            do { _ = try await SnapshotLocalVerifier.verifyAsync(root: destination, snapshot: snapshot); return }
            catch is CancellationError { throw CancellationError() }
            catch { if try referenced(destination, ownedRoot: ownedRoot) { throw SaveSyncError.incompleteSnapshot } }
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let working = parent.appendingPathComponent(".download-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: working) }
        try await copy(working)
        _ = try await SnapshotLocalVerifier.verifyAsync(root: working, snapshot: snapshot)
        try Task.checkCancellation()
        var previous: URL?
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try !referenced(destination, ownedRoot: ownedRoot) else { throw SaveSyncError.incompleteSnapshot }
            try SaveLocalFiles.checkOwnedTree(destination, boundary: ownedRoot)
            let retained = parent.appendingPathComponent(".incomplete-\(UUID().uuidString.lowercased())")
            try FileManager.default.moveItem(at: destination, to: retained); previous = retained
        }
        do {
            try FileManager.default.moveItem(at: working, to: destination)
            try SaveLocalFiles.syncDirectory(parent)
        } catch {
            if let previous, !FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.moveItem(at: previous, to: destination) }
            throw error
        }
        if let previous { try? FileManager.default.removeItem(at: previous) }
    }
    private static func referenced(_ directory: URL, ownedRoot: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("queued-upload.json").path) { return true }
        let transactions = ownedRoot.appendingPathComponent("transactions")
        try SaveLocalFiles.checkOwnedTree(transactions, boundary: ownedRoot)
        guard FileManager.default.fileExists(atPath: transactions.path) else { return false }
        let paths = try FileManager.default.contentsOfDirectory(at: transactions, includingPropertiesForKeys: nil)
        guard paths.count <= 8192 else { throw SaveSyncError.malformedSnapshot }
        for path in paths where path.lastPathComponent.hasSuffix(".json") || path.lastPathComponent.hasSuffix(".json.previous") {
            let data = try SaveLocalFiles.readRegular(path, limit: 65536)
            try BoundedSaveJSON.validate(data)
            guard let journal = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SaveSyncError.malformedSnapshot }
            if journal["snapshotRelativeRoot"] as? String == "staging/" + directory.lastPathComponent { return true }
        }
        return false
    }
}
