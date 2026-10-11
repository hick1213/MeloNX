import Foundation

struct SaveQueuedUpload: Codable, Sendable {
    let version: Int
    let key: SaveBindingKey
    let snapshot: SaveSnapshot
    var published: Bool
    var retired = false
    var acknowledged: Bool
    init(version: Int, key: SaveBindingKey, snapshot: SaveSnapshot, acknowledged: Bool = false, published: Bool = true) {
        self.version = version; self.key = key; self.snapshot = snapshot; self.acknowledged = acknowledged; self.published = published
    }
    private enum CodingKeys: String, CodingKey { case version, key, snapshot, acknowledged, retired, published }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        key = try container.decode(SaveBindingKey.self, forKey: .key)
        snapshot = try container.decode(SaveSnapshot.self, forKey: .snapshot)
        published = try container.decodeIfPresent(Bool.self, forKey: .published) ?? true
        retired = try container.decodeIfPresent(Bool.self, forKey: .retired) ?? false
        acknowledged = try container.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? false
    }
    func acknowledge(ownedRoot: URL) throws {
        var copy = self; copy.acknowledged = true; try copy.persist(ownedRoot: ownedRoot)
    }
    static func root(_ ownedRoot: URL, generation: UUID) -> URL {
        ownedRoot.appendingPathComponent("staging/\(generation.uuidString.lowercased())", isDirectory: true)
    }
    func persist(ownedRoot: URL) throws {
        let data = try SnapshotValidation.encode(self)
        guard data.count <= 65536 else { throw SaveSyncError.malformedSnapshot }
        try SaveLocalFiles.writeDurable(Self.root(ownedRoot, generation: snapshot.generation).appendingPathComponent("queued-upload.json"), data)
    }
    static func loadAsync(ownedRoot: URL, key: SaveBindingKey, binding: SaveBinding?, completedRestore: Bool = false) async throws -> SaveQueuedUpload? {
        let worker = Task.detached(priority: .utility) { try load(ownedRoot: ownedRoot, key: key, binding: binding, completedRestore: completedRestore) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    static func load(ownedRoot: URL, key: SaveBindingKey, binding: SaveBinding?, completedRestore: Bool = false) throws -> SaveQueuedUpload? {
        let staging = ownedRoot.appendingPathComponent("staging")
        try SaveLocalFiles.checkOwnedTree(staging, boundary: ownedRoot)
        guard FileManager.default.fileExists(atPath: staging.path) else { return nil }
        let directories = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard directories.count <= 8192 else { throw SaveSyncError.malformedSnapshot }
        var matches: [SaveQueuedUpload] = []
        for directory in directories {
            guard let generation = UUID(uuidString: directory.lastPathComponent), directory.lastPathComponent == generation.uuidString.lowercased() else { continue }
            try SaveLocalFiles.checkOwnedTree(directory, boundary: staging)
            let path = directory.appendingPathComponent("queued-upload.json")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let data = try SaveLocalFiles.readRegular(path, limit: 65536)
            try BoundedSaveJSON.validate(data)
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.version == 1, value.snapshot.generation == generation, value.snapshot.titleID == value.key.titleID else { throw SaveSyncError.malformedSnapshot }
            try SnapshotValidation.validate(value.snapshot)
            guard value.key == key else { continue }
            if value.acknowledged || value.retired { continue }
            if completedRestore, binding != nil, value.snapshot.parent != binding?.lastGeneration,
               binding?.lastGeneration != generation {
                var retired = value; retired.retired = true
                try retired.persist(ownedRoot: ownedRoot)
                continue
            }
            if binding?.lastGeneration == generation {
                // Persist this receipt before another upload can advance the
                // binding, even if removal of the old staging directory fails.
                try value.acknowledge(ownedRoot: ownedRoot)
                try? value.removeStaging(ownedRoot: ownedRoot)
                continue
            }
            guard value.snapshot.parent == binding?.lastGeneration,
                  value.snapshot.ownerUserID == (binding?.cloudUID ?? key.localUID) else { throw SaveSyncError.conflict }
            _ = try SnapshotLocalVerifier.verify(root: directory, snapshot: value.snapshot)
            matches.append(value)
        }
        guard matches.count <= 1 else { throw SaveSyncError.conflict }
        return matches.first
    }
    func removeStaging(ownedRoot: URL) throws {
        let directory = Self.root(ownedRoot, generation: snapshot.generation)
        try SaveLocalFiles.checkOwnedTree(directory, boundary: ownedRoot)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
            try SaveLocalFiles.syncDirectory(directory.deletingLastPathComponent())
        }
    }
}
