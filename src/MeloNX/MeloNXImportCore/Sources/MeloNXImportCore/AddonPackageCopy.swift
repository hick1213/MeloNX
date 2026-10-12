import Foundation

public enum AddonPackageCopy {
    public static func copy(source: URL, destination: URL, validate: () throws -> Void) throws {
        try validate()
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            guard (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  (try destination.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  manager.contentsEqual(atPath: source.path, andPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
            return // A previous successful copy can be registered again after a JSON write failure.
        }
        let folder = destination.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".addon-import-\(UUID().uuidString)")
        guard !manager.fileExists(atPath: temporary.path) else { throw CocoaError(.fileWriteFileExists) }
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        try manager.moveItem(at: temporary, to: destination)
    }
}
