import Foundation

public enum GameLibraryDeletion {
    /// Keep the visible library unchanged if deleting the ROM fails.
    @MainActor public static func delete<Game>(at url: URL, from games: inout [Game],
                                               fileURL: KeyPath<Game, URL>) throws {
        try FileManager.default.removeItem(at: url)
        games.removeAll { $0[keyPath: fileURL] == url }
    }
}
