import Foundation
import Combine
import UIKit
import MeloNXSaveSyncCore

@MainActor final class SaveSyncCoordinator: ObservableObject {
    static let shared = SaveSyncCoordinator()
    let engine: SaveSyncEngine
    private let bootstrap = SaveRecoveryBootstrap.shared
    private var task: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var identityObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    @Published private(set) var preparationError: String?
    private var configurationError: String?
    var isBusy: Bool { task != nil || engine.isActive }
    var canStart: Bool { !isBusy && configurationError == nil && bootstrap.ready && engine.canStart }
    private init() {
        let root = bootstrap.ownedRoot
        var installation = UUID()
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try SaveLocalFiles.checkOwnedTree(root, boundary: documents)
            let file = root.appendingPathComponent("installation.json")
            if FileManager.default.fileExists(atPath: file.path) {
                installation = try JSONDecoder().decode(UUID.self, from: SaveLocalFiles.readRegular(file, limit: 256))
            } else { try SaveLocalFiles.writeDurable(file, JSONEncoder().encode(installation)) }
        } catch { configurationError = "无法准备存档同步配置。请检查本机存储空间。" }
        engine = SaveSyncEngine(gate: LocalOperations.shared, native: bootstrap.native, cloud: CloudDocumentsStore(),
            bindings: bootstrap.bindings, ownedRoot: root, installationID: installation)
        engine.onChange = { [weak self] in self?.objectWillChange.send() }
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
        preparationError = configurationError
    }
    private func selection(_ game: GameInfo) -> SaveGameSelection? {
        let title = game.titleId.lowercased()
        guard SnapshotValidation.isHex(title, count: 16), let value = UInt64(title, radix: 16), value != 0 else {
            preparationError = "无法识别这个游戏的存档标识。"; return nil
        }
        return SaveGameSelection(titleID: value, gamePath: game.fileURL.path)
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        preparationError = configurationError
        guard configurationError == nil else { return }
        task = Task {
            guard await bootstrap.ensureReady() else {
                preparationError = "启动恢复检查失败。请重试恢复检查。"
                task = nil; objectWillChange.send(); return
            }
            engine.markRecoveryRequired(gameIDs: bootstrap.blockedGames)
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MeloNX Save Sync") { [weak self] in
                Task { @MainActor in self?.cancel() }
            }
            await action()
            // Native, pointer borrowers and local hash workers have actually
            // returned before the engine completes and this owner is released.
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
            }
            task = nil; objectWillChange.send()
        }
        objectWillChange.send()
    }
    func upload(_ game: GameInfo) {
        guard let game = selection(game) else { return }
        run { await self.engine.upload(game) }
    }
    func prepareDownload(_ game: GameInfo) {
        guard let game = selection(game) else { return }
        run { await self.engine.prepareDownload(game) }
    }
    func restore(generation: UUID, allowUserBinding: Bool) {
        run { await self.engine.restorePrepared(generation: generation, allowUserBinding: allowUserBinding) }
    }
    func cancel() { engine.cancel() }
    func retryRecovery() {
        guard task == nil else { return }
        task = Task {
            if !bootstrap.ready {
                if !(await bootstrap.retry()) { preparationError = "恢复检查仍未完成。保留的备份将在下次重试或启动时使用。" }
            } else { await engine.retryRecovery() }
            RyujinxController.shared.loadGames()
            task = nil; objectWillChange.send()
        }
        objectWillChange.send()
    }
}
