import Foundation

public enum SnapshotPaths {
    public static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024, parts.count <= 64,
              !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw SaveSyncError.malformedSnapshot }
    }
    private static func canonical(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    public static func validateEntries(files: [String], emptyDirectories: [String]) throws {
        guard files.count <= 100_000, emptyDirectories.count <= 100_000 - files.count else { throw SaveSyncError.malformedSnapshot }
        let paths = files + emptyDirectories
        var all: Set<String> = []
        for path in paths {
            try validate(path)
            guard all.insert(canonical(path)).inserted else { throw SaveSyncError.malformedSnapshot }
        }
        let terminal = Set(paths.map(canonical))
        // A declared file or empty directory cannot contain another entry.
        for path in all {
            var pieces = path.split(separator: "/").map(String.init)
            while pieces.count > 1 {
                pieces.removeLast()
                guard !terminal.contains(pieces.joined(separator: "/")) else { throw SaveSyncError.malformedSnapshot }
            }
        }
        // Alias collisions also apply to implicit parent directories.
        var aliases: [String: String] = [:]
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            for end in 1...parts.count {
                let actual = parts.prefix(end).joined(separator: "/"), key = canonical(actual)
                if let old = aliases[key], old != actual { throw SaveSyncError.malformedSnapshot }
                aliases[key] = actual
                guard aliases.count <= 100_000 else { throw SaveSyncError.malformedSnapshot }
            }
        }
    }
    public static func recordManifest(key: SaveSlotKey, generation: UUID) -> String {
        "\(String(format: "%016llx", key.programID))/\(key.userID)/\(key.type.rawValue)/\(key.index)/versions/\(generation.uuidString.lowercased())/manifest.json"
    }
    public static func gameManifest(titleID: UInt64, generation: UUID) -> String {
        "\(String(format: "%016llx", titleID))/snapshots/\(generation.uuidString.lowercased())/manifest.json"
    }
}
