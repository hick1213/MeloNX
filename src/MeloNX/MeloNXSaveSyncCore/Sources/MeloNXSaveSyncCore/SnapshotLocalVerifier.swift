import Foundation
import CryptoKit
import Darwin

public enum SnapshotLocalVerifier {
    public static func verifyAsync(root: URL, snapshot: SaveSnapshot) async throws -> Set<String> {
        let worker = Task.detached(priority: .utility) { try verify(root: root, snapshot: snapshot) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func contained(_ root: URL, _ relative: String) throws -> URL {
        try SnapshotPaths.validate(relative)
        try SaveLocalFiles.checkOwnedTree(root)
        var current = root
        let pieces = relative.split(separator: "/")
        for (index, piece) in pieces.enumerated() {
            current.appendPathComponent(String(piece))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path) {
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeDirectory || index == pieces.count - 1 && type == .typeRegular else { throw SaveSyncError.malformedSnapshot }
            }
        }
        return current
    }
    /// Returns every file that must be confirmed by cloud metadata. Manifests are
    /// bounded; payload hashes stream with a 1MiB buffer, including short reads.
    public static func verify(root: URL, snapshot: SaveSnapshot) throws -> Set<String> {
        try SnapshotValidation.validate(snapshot)
        var files: Set<String> = [SnapshotPaths.gameManifest(titleID: snapshot.titleID, generation: snapshot.generation)]
        let gamePath = try contained(root, SnapshotPaths.gameManifest(titleID: snapshot.titleID, generation: snapshot.generation))
        let stored = try SnapshotValidation.decodeSnapshot(SaveLocalFiles.readRegular(gamePath, limit: SnapshotValidation.maxManifestBytes))
        guard try SnapshotValidation.encode(stored) == SnapshotValidation.encode(snapshot) else { throw SaveSyncError.malformedSnapshot }
        var count = 0
        for reference in snapshot.records {
            try Task.checkCancellation()
            let manifest = try contained(root, reference.manifestRelativePath)
            let data = try SaveLocalFiles.readRegular(manifest, limit: SnapshotValidation.maxManifestBytes)
            guard digest(data) == reference.manifestSha256 else { throw SaveSyncError.malformedSnapshot }
            let record = try SnapshotValidation.decodeRecord(data)
            guard record.key == reference.key, record.generation == snapshot.generation else { throw SaveSyncError.malformedSnapshot }
            let relativePayload = String(reference.manifestRelativePath.dropLast("manifest.json".count)) + "payload"
            let payload = try contained(root, relativePayload)
            let inventory = try scan(payload, count: &count)
            let actualFiles = Set(inventory.filter { !$0.value }.map(\.key))
            guard actualFiles == Set(record.files.map(\.path)) else { throw SaveSyncError.malformedSnapshot }
            let empty = emptyDirectories(inventory)
            guard empty == Set(record.emptyDirectories) else { throw SaveSyncError.malformedSnapshot }
            var bytes: Int64 = 0
            files.insert(reference.manifestRelativePath)
            for file in record.files {
                try Task.checkCancellation()
                let path = try contained(payload, file.path)
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.int64Value == file.length else { throw SaveSyncError.malformedSnapshot }
                let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw SaveSyncError.incompleteSnapshot }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var hash = SHA256(), length: Int64 = 0
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    let (next, overflow) = length.addingReportingOverflow(Int64(chunk.count))
                    guard !overflow, next <= file.length else { throw SaveSyncError.malformedSnapshot }
                    length = next; hash.update(data: chunk)
                }
                guard length == file.length, hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw SaveSyncError.malformedSnapshot }
                let (next, overflow) = bytes.addingReportingOverflow(length)
                guard !overflow else { throw SaveSyncError.malformedSnapshot }; bytes = next
                files.insert(relativePayload + "/" + file.path)
            }
            guard bytes == reference.totalBytes else { throw SaveSyncError.malformedSnapshot }
        }
        return files
    }
    private static func emptyDirectories(_ entries: [String: Bool]) -> Set<String> {
        var parents: Set<String> = []
        for path in entries.keys {
            if let slash = path.lastIndex(of: "/") { parents.insert(String(path[..<slash])) }
        }
        return Set(entries.filter { $0.value }.map(\.key)).subtracting(parents)
    }
    private static func scan(_ root: URL, count: inout Int) throws -> [String: Bool] {
        try SaveLocalFiles.checkOwnedTree(root)
        guard FileManager.default.fileExists(atPath: root.path) else { throw SaveSyncError.incompleteSnapshot }
        var entries: [String: Bool] = [:], pending: [(URL, String)] = [(root, "")]
        while let (directory, prefix) = pending.popLast() {
            try Task.checkCancellation()
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                count += 1; guard count <= 100_000 else { throw SaveSyncError.malformedSnapshot }
                let relative = prefix + item.lastPathComponent
                try SnapshotPaths.validate(relative)
                let type = try FileManager.default.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular else { throw SaveSyncError.malformedSnapshot }
                entries[relative] = type == .typeDirectory
                if type == .typeDirectory { pending.append((item, relative + "/")) }
            }
        }
        try SnapshotPaths.validateEntries(files: entries.filter { !$0.value }.map(\.key), emptyDirectories: Array(emptyDirectories(entries)))
        return entries
    }
}
