import Foundation
import MeloNXSaveSyncCore

actor CloudDocumentsStore: CloudSaveStore {
    static let container = "iCloud.com.hick.MeloNX"
    private let identities = CloudIdentityStore()
    private let files = CloudFileCoordinator()
    private var roots: [CloudIdentity: URL] = [:]
    private var publications: [UUID: Set<String>] = [:]
    func identity() async throws -> CloudIdentity {
        let value = try await identities.identity(container: Self.container)
        if roots[value] == nil {
            // Actor executor, never the main thread. Explicit container only.
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: Self.container) else { throw SaveSyncError.cloudUnavailable }
            let owned = container.appendingPathComponent("Documents/MeloNX/Saves/v1", isDirectory: true)
            try SaveLocalFiles.checkOwnedTree(owned, boundary: container)
            roots[value] = owned
        }
        try await check(value)
        if let root = roots[value] {
            let documents = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try SaveLocalFiles.checkOwnedTree(root, boundary: documents)
        }
        return value
    }
    private func check(_ identity: CloudIdentity) async throws {
        try Task.checkCancellation()
        guard try await identities.identity(container: Self.container) == identity else { throw SaveSyncError.identityMismatch }
    }
    private func root(_ identity: CloudIdentity) async throws -> URL {
        guard try await self.identity() == identity, let root = roots[identity] else { throw SaveSyncError.identityMismatch }
        return root
    }
    private func coordinate<T: Sendable>(_ url: URL, writing: Bool, identity: CloudIdentity,
                                         body: @escaping @Sendable (URL) throws -> T) async throws -> T {
        let token = try await identities.capture(identity)
        do {
            let result = try await files.coordinate(url, writing: writing) { url in
                try token.check()
                let result = try body(url)
                try token.check()
                return result
            }
            try token.check()
            return result
        } catch { try token.check(); throw error }
    }
    func publish(localRoot: URL, snapshot: SaveSnapshot, identity: CloudIdentity) async throws {
        let files = try SnapshotLocalVerifier.verify(root: localRoot, snapshot: snapshot)
        let root = try await root(identity)
        let gamePath = SnapshotPaths.gameManifest(titleID: snapshot.titleID, generation: snapshot.generation)
        // Resume an immutable UUID generation, accepting only identical existing files.
        for record in snapshot.records {
            let target = try SnapshotLocalVerifier.contained(root, record.manifestRelativePath).deletingLastPathComponent()
            try await check(identity)
            try await coordinate(target, writing: true, identity: identity) { target in
                try SaveLocalFiles.checkOwnedTree(target, boundary: root)
                try FileManager.default.createDirectory(at: target.appendingPathComponent("payload"), withIntermediateDirectories: true)
            }
            let localManifest = try SnapshotLocalVerifier.contained(localRoot, record.manifestRelativePath)
            let manifest = try SnapshotValidation.decodeRecord(SaveLocalFiles.readRegular(localManifest, limit: SnapshotValidation.maxManifestBytes))
            for directory in manifest.emptyDirectories {
                let path = try SnapshotLocalVerifier.contained(target.appendingPathComponent("payload"), directory)
                try await check(identity)
                try await coordinate(path, writing: true, identity: identity) { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
            }
        }
        let recordFiles = files.subtracting([gamePath]).sorted { a, b in
            // Local payload files first, then their immutable record manifests.
            let left = a.hasSuffix("/manifest.json"), right = b.hasSuffix("/manifest.json")
            return left == right ? a < b : !left
        }
        for relative in recordFiles + [gamePath] {
            try await check(identity)
            let source = try SnapshotLocalVerifier.contained(localRoot, relative)
            let target = try SnapshotLocalVerifier.contained(root, relative)
            try await coordinate(target, writing: true, identity: identity) { url in
                guard NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty != false else { throw SaveSyncError.conflict }
                try SaveImmutablePublication.copy(source: source, destination: url, temporaryRoot: root.appendingPathComponent(".publication-staging"))
            }
        }
        try await check(identity)
        if publications.count >= 64 { publications.removeAll() }
        publications[snapshot.generation] = files
    }
    func waitUploaded(snapshot: SaveSnapshot, identity: CloudIdentity) async throws {
        let root = try await root(identity)
        let files: Set<String>
        if let published = publications[snapshot.generation] { files = published }
        else {
            // A private queued-upload receipt survives process death. Rebuild
            // the expected file set, then confirm every upload flag again.
            do {
                try await materialize(snapshot, root: root, identity: identity, deadline: Date().addingTimeInterval(30))
                files = try SnapshotLocalVerifier.verify(root: root, snapshot: snapshot)
            } catch SaveSyncError.incompleteSnapshot { throw SaveSyncError.queued }
        }
        try await wait(files: files, root: root, identity: identity, direction: .upload)
        try await check(identity)
        publications.removeValue(forKey: snapshot.generation)
    }
    private func wait(files: Set<String>, root: URL, identity: CloudIdentity, direction: CloudTransferDirection, deadline: Date? = nil) async throws {
        let confirmation = CloudTransferConfirmation(identity: identity, requiredFiles: files)
        if direction == .download {
            for relative in files {
                try await check(identity)
                let path = try SnapshotLocalVerifier.contained(root, relative)
                try FileManager.default.startDownloadingUbiquitousItem(at: path)
            }
        }
        let _: Bool = try await CloudTransferObserver.wait(root: root, timeout: max(0.1, min(30, deadline?.timeIntervalSinceNow ?? 30)), expiry: direction == .upload ? .queued : .incompleteSnapshot) { _, _ in
            let current = try await self.identity()
            let states = try await self.states(root: root, files: files)
            return try confirmation.confirm(current: current, states: states, direction: direction) ? true : nil
        }
    }
    private func states(root: URL, files: Set<String>) throws -> [String: CloudFileState] {
        try CloudTransferObserver.fileStates(root: root, required: files)
    }
    private func readManifest(_ relative: String, root: URL, identity: CloudIdentity, deadline: Date? = nil) async throws -> Data {
        try await wait(files: [relative], root: root, identity: identity, direction: .download, deadline: deadline)
        try await check(identity)
        let file = try SnapshotLocalVerifier.contained(root, relative)
        let data = try await coordinate(file, writing: false, identity: identity) { try SaveLocalFiles.readRegular($0, limit: SnapshotValidation.maxManifestBytes) }
        try await check(identity)
        return data
    }
    private func materialize(_ snapshot: SaveSnapshot, root: URL, identity: CloudIdentity, deadline: Date? = nil) async throws {
        try SnapshotValidation.validate(snapshot)
        var files: Set<String> = [SnapshotPaths.gameManifest(titleID: snapshot.titleID, generation: snapshot.generation)]
        var entries = 0
        for reference in snapshot.records {
            let data = try await readManifest(reference.manifestRelativePath, root: root, identity: identity, deadline: deadline)
            guard SnapshotLocalVerifier.digest(data) == reference.manifestSha256 else { throw SaveSyncError.malformedSnapshot }
            let record = try SnapshotValidation.decodeRecord(data)
            guard record.key == reference.key, record.generation == snapshot.generation else { throw SaveSyncError.malformedSnapshot }
            entries += record.files.count + record.emptyDirectories.count
            guard entries <= 100_000 else { throw SaveSyncError.malformedSnapshot }
            files.insert(reference.manifestRelativePath)
            let payload = String(reference.manifestRelativePath.dropLast("manifest.json".count)) + "payload/"
            for file in record.files { files.insert(payload + file.path) }
        }
        try await wait(files: files, root: root, identity: identity, direction: .download, deadline: deadline)
        try await check(identity)
        // All files are already current. This is local verification; no transfer
        // wait or hash loop is enclosed by a coordinated read.
        _ = try SnapshotLocalVerifier.verify(root: root, snapshot: snapshot)
    }
    func list(titleID: UInt64, identity: CloudIdentity) async throws -> CloudListing {
        let root = try await root(identity)
        let title = String(format: "%016llx", titleID), prefix = root.appendingPathComponent(title + "/snapshots")
        let urls: [URL] = try await CloudTransferObserver.wait(root: root, timeout: 15, expiry: .queued) { query, gathered in
            guard gathered, !query.isGathering else { return nil }
            var urls: [URL] = []
            for index in 0..<query.resultCount {
                if let item = query.result(at: index) as? NSMetadataItem, let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL { urls.append(url) }
            }
            try await self.check(identity)
            return urls
        }
        var generations: Set<UUID> = []
        for url in urls where url.path.hasPrefix(prefix.path + "/") {
            let name = String(url.path.dropFirst(prefix.path.count + 1).split(separator: "/").first ?? "")
            if let generation = UUID(uuidString: name) { generations.insert(generation) }
        }
        if FileManager.default.fileExists(atPath: prefix.path) {
            try SaveLocalFiles.checkOwnedTree(prefix, boundary: root)
            for url in try FileManager.default.contentsOfDirectory(at: prefix, includingPropertiesForKeys: nil) {
                if let generation = UUID(uuidString: url.lastPathComponent) { generations.insert(generation) }
            }
        }
        guard generations.count <= 8192 else { throw SaveSyncError.malformedSnapshot }
        let deadline = Date().addingTimeInterval(60)
        var versions: [VisibleSnapshot] = [], unreadable: Set<UUID> = []
        for generation in generations {
            if Date() >= deadline { unreadable.insert(generation); continue }
            try await check(identity)
            do {
                let data = try await readManifest(SnapshotPaths.gameManifest(titleID: titleID, generation: generation), root: root, identity: identity, deadline: deadline)
                let snapshot = try SnapshotValidation.decodeSnapshot(data)
                guard snapshot.titleID == titleID, snapshot.generation == generation else { throw SaveSyncError.malformedSnapshot }
                versions.append(VisibleSnapshot(snapshot: snapshot, availability: .pending))
            } catch is CancellationError { throw CancellationError() }
            catch SaveSyncError.identityMismatch { throw SaveSyncError.identityMismatch }
            catch { unreadable.insert(generation) }
        }
        // Verify candidate heads; older manifests stay visible but are not
        // downloaded unnecessarily. Pending descendants never select old parents.
        let parents = Set(versions.compactMap { $0.snapshot.parent })
        for index in versions.indices where !parents.contains(versions[index].snapshot.generation) {
            if Date() >= deadline { break }
            do {
                try await materialize(versions[index].snapshot, root: root, identity: identity, deadline: deadline)
                versions[index] = VisibleSnapshot(snapshot: versions[index].snapshot, availability: .verified)
            } catch is CancellationError { throw CancellationError() }
            catch SaveSyncError.identityMismatch { throw SaveSyncError.identityMismatch }
            catch { /* Keep the visible successor pending. */ }
        }
        try await check(identity)
        return CloudListing(versions: versions, unreadableGenerations: unreadable)
    }
    func download(snapshot: SaveSnapshot, into destination: URL, identity: CloudIdentity) async throws {
        let root = try await root(identity)
        try await materialize(snapshot, root: root, identity: identity, deadline: Date().addingTimeInterval(120))
        try await SaveDownloadStaging.download(destination: destination, snapshot: snapshot) { working in
            try await self.copyDownloaded(snapshot: snapshot, root: root, destination: working, identity: identity)
        }
        try await check(identity)
    }
    private func copyDownloaded(snapshot: SaveSnapshot, root: URL, destination: URL, identity: CloudIdentity) async throws {
        for reference in snapshot.records {
            try await check(identity)
            let source = try SnapshotLocalVerifier.contained(root, reference.manifestRelativePath).deletingLastPathComponent()
            let target = try SnapshotLocalVerifier.contained(destination, reference.manifestRelativePath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await coordinate(source, writing: false, identity: identity) { try FileManager.default.copyItem(at: $0, to: target) }
        }
        let relative = SnapshotPaths.gameManifest(titleID: snapshot.titleID, generation: snapshot.generation)
        let source = try SnapshotLocalVerifier.contained(root, relative), target = try SnapshotLocalVerifier.contained(destination, relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await coordinate(source, writing: false, identity: identity) { try FileManager.default.copyItem(at: $0, to: target) }
        _ = try SnapshotLocalVerifier.verify(root: destination, snapshot: snapshot)
        try await check(identity)
    }
}
