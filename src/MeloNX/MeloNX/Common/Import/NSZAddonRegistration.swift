import Foundation
import MeloNXImportCore

enum NSZAddonRegistration {
    static func update(_ file: NSZImportedFile, applicationID: UInt64) throws {
        try NSZAddonStore(documents: .documentsDirectory).registerUpdate(file, applicationID: applicationID, cancelled: Task.isCancelled)
    }
    static func dlc(_ file: NSZImportedFile, applicationID: UInt64) throws {
        if Task.isCancelled { throw CancellationError() }
        _ = try NSZAddonStore(documents: .documentsDirectory).relativePath(file, kind: 2, applicationID: applicationID)
        let title = String(format: "%016llx", applicationID)
        let list = Ryujinx.getDlcNcaList(titleId: title, path: file.path)
        guard !list.isEmpty else { throw NSZNativeFailure(code: "invalid_package") }
        let entries = list.map { NSZDlcEntry(path: $0.fullPath, titleID: $0.titleId, enabled: $0.enabled) }
        try NSZAddonStore(documents: .documentsDirectory).registerDLC(file, applicationID: applicationID, entries: entries, cancelled: Task.isCancelled)
    }
}
