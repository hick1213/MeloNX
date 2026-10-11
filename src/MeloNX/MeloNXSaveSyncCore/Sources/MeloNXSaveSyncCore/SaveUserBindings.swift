import Foundation
import Darwin

public struct SaveBindingKey: Codable, Hashable, Sendable {
    public let localCloudAccountUUID: UUID
    public let container: String
    public let titleID: UInt64
    public let localUID: String
    public init(localCloudAccountUUID: UUID, container: String, titleID: UInt64, localUID: String) {
        self.localCloudAccountUUID = localCloudAccountUUID; self.container = container
        self.titleID = titleID; self.localUID = localUID
    }
}
public struct SaveBinding: Codable, Equatable, Sendable {
    public let cloudUID: String
    public let lastGeneration: UUID
    public init(cloudUID: String, lastGeneration: UUID) { self.cloudUID = cloudUID; self.lastGeneration = lastGeneration }
}

/// Private, atomically replaced state. A journal is acknowledged only after this
/// writer has synchronized both the new file and the containing directory.
public final class SaveUserBindings: @unchecked Sendable {
    private struct Entry: Codable {
        let key: SaveBindingKey; let value: SaveBinding; let completedRestore: Bool
        init(key: SaveBindingKey, value: SaveBinding, completedRestore: Bool) {
            self.key = key; self.value = value; self.completedRestore = completedRestore
        }
        private enum CodingKeys: String, CodingKey { case key, value, completedRestore }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(SaveBindingKey.self, forKey: .key)
            value = try c.decode(SaveBinding.self, forKey: .value)
            completedRestore = try c.decodeIfPresent(Bool.self, forKey: .completedRestore) ?? false
        }
    }
    private struct State: Codable { var version = 1; var entries: [Entry] = []; var applied: Set<UUID> = [] }
    private let lock = NSLock()
    private let root: URL
    private let write: @Sendable (URL, Data) throws -> Void
    public init(root: URL, write: @escaping @Sendable (URL, Data) throws -> Void = SaveLocalFiles.writeDurable) {
        self.root = root; self.write = write
    }
    private func load() throws -> State {
        try SaveLocalFiles.checkOwnedTree(root)
        let path = root.appendingPathComponent("bindings.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return State() }
        let data = try SaveLocalFiles.readRegular(path, limit: 4 * 1024 * 1024)
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.version == 1, state.entries.count <= 8192,
              Set(state.entries.map(\.key)).count == state.entries.count else { throw SaveSyncError.identityMismatch }
        return state
    }
    public func read(key: SaveBindingKey) throws -> SaveBinding? {
        lock.lock(); defer { lock.unlock() }
        return try load().entries.first { $0.key == key }?.value
    }
    public func hasCompletedRestore(key: SaveBindingKey) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try load().entries.first { $0.key == key }?.completedRestore ?? false
    }
    private func record(_ key: SaveBindingKey, _ value: SaveBinding, transaction: UUID?) throws {
        var state = try load()
        if let transaction, state.applied.contains(transaction) { return }
        _ = try SaveBindingIntent(accountKey: key.localCloudAccountUUID, container: key.container, titleID: key.titleID,
                                  localUID: key.localUID, cloudUID: value.cloudUID, generation: value.lastGeneration).validate()
        state.entries.removeAll { $0.key == key }; state.entries.append(Entry(key: key, value: value, completedRestore: transaction != nil))
        if let transaction { state.applied.insert(transaction) }
        let data = try JSONEncoder().encode(state)
        guard state.entries.count <= 8192, data.count <= 4 * 1024 * 1024 else { throw SaveSyncError.identityMismatch }
        try write(root.appendingPathComponent("bindings.json"), data)
    }
    public func recordUploaded(key: SaveBindingKey, cloudUID: String, generation: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try record(key, SaveBinding(cloudUID: cloudUID, lastGeneration: generation), transaction: nil)
    }
    public func applyCompleted(intent: SaveBindingIntent, transactionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let title = try intent.validate()
        try record(SaveBindingKey(localCloudAccountUUID: intent.accountKey, container: intent.container, titleID: title, localUID: intent.localUserId),
                   SaveBinding(cloudUID: intent.cloudUserId, lastGeneration: intent.generation), transaction: transactionID)
    }
    public func applyCompleted(intentFile: URL, transactionID: UUID) throws {
        let intent = try JSONDecoder().decode(SaveBindingIntent.self, from: SaveLocalFiles.readRegular(intentFile, limit: 65536))
        try applyCompleted(intent: intent, transactionID: transactionID)
    }
}

public enum SaveLocalFiles {
    /// Checks every existing node from the supplied app-owned boundary. System
    /// aliases outside that boundary (notably /var on iOS) are not followed here.
    public static func checkOwnedTree(_ root: URL, boundary: URL? = nil) throws {
        let boundary = (boundary ?? root).standardizedFileURL
        let target = root.standardizedFileURL
        guard target.path == boundary.path || target.path.hasPrefix(boundary.path + "/") else { throw SaveSyncError.malformedSnapshot }
        var current = boundary
        let relative = target.path.dropFirst(boundary.path.count).split(separator: "/")
        for component in [String?](arrayLiteral: nil) + relative.map({ Optional(String($0)) }) {
            if let component { current.appendPathComponent(component) }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SaveSyncError.malformedSnapshot }
            }
        }
    }
    public static func readRegular(_ path: URL, limit: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= limit else { throw SaveSyncError.malformedSnapshot }
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SaveSyncError.malformedSnapshot }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, data.count == size.int64Value else { throw SaveSyncError.malformedSnapshot }
        return data
    }
    public static func writeDurable(_ path: URL, _ data: Data) throws {
        let directory = path.deletingLastPathComponent()
        try checkOwnedTree(directory)
        var missing: [URL] = [], ancestor = directory
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            missing.append(ancestor)
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw SaveSyncError.restoreFailed }
            ancestor = parent
        }
        for created in missing.reversed() {
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
            try syncDirectory(created.deletingLastPathComponent())
        }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SaveSyncError.restoreFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, path.path) == 0 else { throw SaveSyncError.restoreFailed }
        try syncDirectory(directory)
    }
    public static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SaveSyncError.restoreFailed }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw SaveSyncError.restoreFailed }
    }
}
