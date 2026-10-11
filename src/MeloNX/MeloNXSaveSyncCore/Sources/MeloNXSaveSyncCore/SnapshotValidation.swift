import Foundation

public enum SnapshotValidation {
    public static let maxManifestBytes = 4 * 1024 * 1024
    public static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func validateKey(_ key: SaveSlotKey) throws {
        guard key.programID != 0 else { throw SaveSyncError.malformedSnapshot }
        switch key.type {
        case .account: guard isHex(key.userID, count: 32), key.userID != String(repeating: "0", count: 32) else { throw SaveSyncError.malformedSnapshot }
        case .device: guard key.userID == "shared" else { throw SaveSyncError.malformedSnapshot }
        }
    }
    public static func validate(_ snapshot: SaveSnapshot) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: snapshot.createdUTC)
        formatter.formatOptions = [.withInternetDateTime]
        let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        guard snapshot.schemaVersion == 1, snapshot.titleID != 0, snapshot.parent != snapshot.generation,
              snapshot.generation != zeroUUID, snapshot.installationID != zeroUUID,
              isHex(snapshot.ownerUserID, count: 32), snapshot.ownerUserID != String(repeating: "0", count: 32),
              snapshot.createdUTC.hasSuffix("Z"), (fractional ?? formatter.date(from: snapshot.createdUTC)) != nil,
              snapshot.records.count > 0, snapshot.records.count <= 64, snapshot.totalBytes >= 0 else { throw SaveSyncError.malformedSnapshot }
        var keys: Set<SaveSlotKey> = []; var sum: Int64 = 0
        for record in snapshot.records {
            try validateKey(record.key)
            guard record.key.programID == snapshot.titleID, keys.insert(record.key).inserted,
                  record.key.type != .account || record.key.userID == snapshot.ownerUserID,
                  record.totalBytes >= 0, isHex(record.manifestSha256, count: 64),
                  record.manifestRelativePath == SnapshotPaths.recordManifest(key: record.key, generation: snapshot.generation) else { throw SaveSyncError.malformedSnapshot }
            let (next, overflow) = sum.addingReportingOverflow(record.totalBytes)
            guard !overflow else { throw SaveSyncError.malformedSnapshot }; sum = next
        }
        guard sum == snapshot.totalBytes else { throw SaveSyncError.malformedSnapshot }
    }
    public static func validateRecord(_ record: SaveRecordManifest) throws {
        guard record.schemaVersion == 1,
              record.generation != UUID(uuidString: "00000000-0000-0000-0000-000000000000")! else { throw SaveSyncError.malformedSnapshot }
        try validateKey(record.key)
        try SnapshotPaths.validateEntries(files: record.files.map(\.path), emptyDirectories: record.emptyDirectories)
        var total: Int64 = 0
        for file in record.files {
            guard file.length >= 0, isHex(file.sha256, count: 64) else { throw SaveSyncError.malformedSnapshot }
            let (next, overflow) = total.addingReportingOverflow(file.length)
            guard !overflow else { throw SaveSyncError.malformedSnapshot }; total = next
        }
    }
    public static func decodeSnapshot(_ data: Data) throws -> SaveSnapshot {
        guard data.count <= maxManifestBytes else { throw SaveSyncError.malformedSnapshot }
        do { let value = try JSONDecoder().decode(SaveSnapshot.self, from: data); try validate(value); return value }
        catch { throw SaveSyncError.malformedSnapshot }
    }
    public static func decodeRecord(_ data: Data) throws -> SaveRecordManifest {
        guard data.count <= maxManifestBytes else { throw SaveSyncError.malformedSnapshot }
        do { let value = try JSONDecoder().decode(SaveRecordManifest.self, from: data); try validateRecord(value); return value }
        catch { throw SaveSyncError.malformedSnapshot }
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maxManifestBytes else { throw SaveSyncError.malformedSnapshot }
        return data
    }
}
