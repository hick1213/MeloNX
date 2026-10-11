import Foundation
import Darwin

/// Reuses identical immutable files after an interrupted publication. Existing
/// conflicting files are never replaced; reads stay bounded to two 1MiB buffers.
public enum SaveImmutablePublication {
    public static func copy(source: URL, destination: URL, temporaryRoot: URL? = nil) throws {
        try SaveLocalFiles.checkOwnedTree(destination.deletingLastPathComponent())
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path) {
            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  sourceAttributes[.type] as? FileAttributeType == .typeRegular,
                  attributes[.size] as? NSNumber == sourceAttributes[.size] as? NSNumber else { throw SaveSyncError.conflict }
            func openFile(_ url: URL) throws -> FileHandle {
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw SaveSyncError.conflict }
                return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            }
            let left = try openFile(source), right = try openFile(destination)
            defer { try? left.close(); try? right.close() }
            while true {
                try Task.checkCancellation()
                let a = try left.read(upToCount: 1024 * 1024) ?? Data()
                let b = try right.read(upToCount: 1024 * 1024) ?? Data()
                guard a == b else { throw SaveSyncError.conflict }
                if a.isEmpty { return }
            }
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let temporaryRoot {
            try SaveLocalFiles.checkOwnedTree(temporaryRoot)
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        }
        let temporary = (temporaryRoot ?? destination.deletingLastPathComponent()).appendingPathComponent(".publication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
