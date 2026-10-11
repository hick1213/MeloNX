import Foundation

public enum SaveSyncError: Error, Sendable {
    case noSave, busy, cloudUnavailable, queued, quota, incompleteSnapshot, conflict
    case identityMismatch, malformedSnapshot, restoreFailed, rollbackRequired
}
public enum SaveSlotType: String, Codable, Sendable { case account = "Account", device = "Device" }

public struct SaveSlotKey: Hashable, Codable, Sendable {
    public let programID: UInt64
    public let userID: String
    public let type: SaveSlotType
    public let index: UInt16
    public init(programID: UInt64, userID: String, type: SaveSlotType, index: UInt16) {
        self.programID = programID; self.userID = userID; self.type = type; self.index = index
    }
    private enum CodingKeys: String, CodingKey { case programID, userID, type, index }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .programID)
        guard SnapshotValidation.isHex(id, count: 16), let program = UInt64(id, radix: 16) else { throw SaveSyncError.malformedSnapshot }
        programID = program; userID = try c.decode(String.self, forKey: .userID)
        type = try c.decode(SaveSlotType.self, forKey: .type); index = try c.decode(UInt16.self, forKey: .index)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(String(format: "%016llx", programID), forKey: .programID)
        try c.encode(userID, forKey: .userID); try c.encode(type, forKey: .type); try c.encode(index, forKey: .index)
    }
}
public struct SaveFileEntry: Codable, Sendable {
    public let path: String; public let length: Int64; public let sha256: String
    public init(path: String, length: Int64, sha256: String) { self.path = path; self.length = length; self.sha256 = sha256 }
}
public struct SaveRecordManifest: Codable, Sendable {
    public let schemaVersion: Int; public let generation: UUID; public let key: SaveSlotKey
    public let files: [SaveFileEntry]; public let emptyDirectories: [String]
    public init(schemaVersion: Int, generation: UUID, key: SaveSlotKey, files: [SaveFileEntry], emptyDirectories: [String]) {
        self.schemaVersion = schemaVersion; self.generation = generation; self.key = key
        self.files = files; self.emptyDirectories = emptyDirectories
    }
}
public struct SaveRecordReference: Codable, Sendable {
    public let key: SaveSlotKey; public let manifestRelativePath: String
    public let manifestSha256: String; public let totalBytes: Int64
    public init(key: SaveSlotKey, manifestRelativePath: String, manifestSha256: String, totalBytes: Int64) {
        self.key = key; self.manifestRelativePath = manifestRelativePath
        self.manifestSha256 = manifestSha256; self.totalBytes = totalBytes
    }
}
public struct SaveSnapshot: Codable, Sendable {
    public let schemaVersion: Int; public let generation: UUID; public let parent: UUID?
    public let titleID: UInt64; public let ownerUserID: String; public let createdUTC: String
    public let installationID: UUID; public let totalBytes: Int64; public let records: [SaveRecordReference]
    public init(schemaVersion: Int, generation: UUID, parent: UUID?, titleID: UInt64, ownerUserID: String,
                createdUTC: String, installationID: UUID, totalBytes: Int64, records: [SaveRecordReference]) {
        self.schemaVersion = schemaVersion; self.generation = generation; self.parent = parent; self.titleID = titleID
        self.ownerUserID = ownerUserID; self.createdUTC = createdUTC; self.installationID = installationID
        self.totalBytes = totalBytes; self.records = records
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, generation, parent, titleID, ownerUserID, createdUTC, installationID, totalBytes, records }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .titleID)
        guard SnapshotValidation.isHex(id, count: 16), let title = UInt64(id, radix: 16) else { throw SaveSyncError.malformedSnapshot }
        titleID = title; schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        generation = try c.decode(UUID.self, forKey: .generation); parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
        ownerUserID = try c.decode(String.self, forKey: .ownerUserID); createdUTC = try c.decode(String.self, forKey: .createdUTC)
        installationID = try c.decode(UUID.self, forKey: .installationID); totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
        records = try c.decode([SaveRecordReference].self, forKey: .records)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(generation.uuidString.lowercased(), forKey: .generation)
        try c.encode(parent?.uuidString.lowercased(), forKey: .parent)
        try c.encode(String(format: "%016llx", titleID), forKey: .titleID)
        try c.encode(ownerUserID, forKey: .ownerUserID); try c.encode(createdUTC, forKey: .createdUTC)
        try c.encode(installationID.uuidString.lowercased(), forKey: .installationID)
        try c.encode(totalBytes, forKey: .totalBytes); try c.encode(records, forKey: .records)
    }
}
public enum SnapshotAvailability: Sendable { case pending, verified }
public struct VisibleSnapshot: Sendable {
    public let snapshot: SaveSnapshot; public let availability: SnapshotAvailability
    public init(snapshot: SaveSnapshot, availability: SnapshotAvailability) { self.snapshot = snapshot; self.availability = availability }
}
public struct CloudListing: Sendable {
    public let versions: [VisibleSnapshot]; public let unreadableGenerations: Set<UUID>
    public init(versions: [VisibleSnapshot], unreadableGenerations: Set<UUID>) { self.versions = versions; self.unreadableGenerations = unreadableGenerations }
}
public enum CloudHeadSelection: Equatable, Sendable { case none, ready(UUID), pending(Set<UUID>), conflict(Set<UUID>) }
