import SwiftUI
import MeloNXSaveSyncCore

struct GameSaveSyncView: View {
    @EnvironmentObject private var controller: RyujinxController
    @ObservedObject private var sync: SaveSyncCoordinator
    private let fixtureGames: [GameInfo]?
    @State private var selectedGame: GameInfo?
    @State private var chosenGeneration: UUID?
    @State private var showConfirmation = false
    @State private var showHistory = false
    init(game: GameInfo? = nil, coordinator: SaveSyncCoordinator = .shared, fixtureGames: [GameInfo]? = nil) {
        _selectedGame = State(initialValue: game); _sync = ObservedObject(wrappedValue: coordinator); self.fixtureGames = fixtureGames
    }
    private var matchesPreparedGame: Bool { selectedGame.flatMap { UInt64($0.titleId, radix: 16) } == sync.engine.preparedGameID && sync.engine.preparedGameID != nil }
    private var chosen: SaveSnapshot? {
        guard matchesPreparedGame else { return nil }
        let generation = chosenGeneration ?? sync.engine.defaultGeneration
        return sync.engine.versions.first { $0.snapshot.generation == generation }?.snapshot
    }
    private var presentation: SaveSyncPresentation { SaveSyncPresentation(phase: sync.engine.phase, error: sync.engine.error) }
    var body: some View {
        Form {
            Section {
                Picker("Game", selection: $selectedGame) {
                    Text("Choose a game").tag(Optional<GameInfo>.none)
                    ForEach(fixtureGames ?? controller.games) { game in Text(game.titleName).tag(Optional(game)) }
                }
                .disabled(sync.isBusy)
                .accessibilityIdentifier("saveSync.game")
                Label("Current emulator user", systemImage: "person.crop.circle")
                Text("Exit the game after saving. Upload and restore require the game and JIT tasks to be stopped.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { if let selectedGame { chosenGeneration = nil; sync.upload(selectedGame) } } label: {
                    Label(sync.engine.phase == .queued ? "Retry Pending Upload" : "Upload Save", systemImage: "icloud.and.arrow.up")
                }
                .disabled(selectedGame == nil || !sync.canStart)
                .accessibilityIdentifier("saveSync.upload")
                Button { if let selectedGame { chosenGeneration = nil; sync.prepareDownload(selectedGame) } } label: {
                    Label("Download Save", systemImage: "icloud.and.arrow.down")
                }
                .disabled(selectedGame == nil || !sync.canStart)
                .accessibilityIdentifier("saveSync.download")
            }
            if sync.isBusy || sync.engine.phase != .idle || sync.engine.restoredGeneration != nil {
                Section("Status") {
                    HStack(alignment: .top) {
                        if sync.isBusy { ProgressView().accessibilityLabel("Save operation in progress") }
                        Text(status)
                    }
                    .accessibilityIdentifier("saveSync.status")
                    if let message = sync.preparationError { Text(message).foregroundStyle(.orange) }
                    if let error = sync.engine.error { Text(error.localizedDescription).foregroundStyle(.orange) }
                    if sync.isBusy, sync.engine.phase != .finishing {
                        Button("Cancel", role: .cancel) { sync.cancel() }
                            .accessibilityIdentifier("saveSync.cancel")
                    }
                }
            } else if let message = sync.preparationError {
                Section("Status") { Text(message).foregroundStyle(.orange) }
            }
            if matchesPreparedGame && !sync.engine.versions.isEmpty && !sync.isBusy {
                Section("Cloud Save") {
                    if let chosen {
                        Text(chosen.createdUTC).font(.subheadline)
                        Text(ByteCountFormatter.string(fromByteCount: chosen.totalBytes, countStyle: .file)).foregroundStyle(.secondary)
                        Button("Restore Save") { showConfirmation = true }
                            .disabled(!sync.canStart)
                            .accessibilityIdentifier("saveSync.restore")
                    } else {
                        Text(sync.engine.pendingGenerations.isEmpty ? "Choose a cloud version to restore." : "A newer version is still downloading. Refresh before restoring.")
                    }
                    if presentation.showsVersionChoice || sync.engine.defaultGeneration == nil {
                        Button("Choose Cloud Version") { showHistory = true }
                    } else {
                        Button("Browse Older Versions") { showHistory = true }
                    }
                    if presentation.canRetry, let selectedGame {
                        Button("Refresh Versions") { chosenGeneration = nil; sync.prepareDownload(selectedGame) }
                    }
                }
            }
            if !sync.engine.blockedGames.isEmpty || SaveRecoveryBootstrap.shared.failed || !SaveRecoveryBootstrap.shared.blockedGames.isEmpty {
                Section("Save Recovery") {
                    Text("An interrupted restore must be recovered before the affected game can start. Its backups are retained.")
                    Button("Retry Recovery") { sync.retryRecovery() }.disabled(sync.isBusy)
                }
            }
            Section {
                Text("Select a game to sync its current user's save with your iCloud Drive. Cloud versions and restore backups are retained.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("iCloud Saves")
        .sheet(isPresented: $showHistory) {
            CloudSaveVersionsView(versions: sync.engine.versions, selected: chosenGeneration ?? sync.engine.defaultGeneration) { generation in
                chosenGeneration = generation; showHistory = false
            }
        }
        .sheet(isPresented: $showConfirmation) {
            if let chosen {
                SaveRestoreConfirmation(snapshot: chosen, localUserID: sync.engine.localUserID,
                    expectedCloudUserID: sync.engine.expectedCloudUserID) { allowBinding in
                    showConfirmation = false; sync.restore(generation: chosen.generation, allowUserBinding: allowBinding)
                }
            }
        }
        .interactiveDismissDisabled(sync.isBusy)
        .onChange(of: selectedGame) { _ in chosenGeneration = nil; sync.engine.resetSelection() }
        .onDisappear { if sync.isBusy { sync.cancel() } }
    }
    private var status: LocalizedStringKey {
        if sync.engine.restoredGeneration != nil {
            if sync.engine.phase == .failed { return "The original user's save was restored. Refresh after the account change." }
            if sync.engine.phase == .cancelled { return "Restore completed before cancellation took effect." }
            return "Save restore completed."
        }
        switch sync.engine.phase {
        case .idle: return "Ready"
        case .exporting: return "Creating a stable save snapshot…"
        case .publishing: return "Waiting for every file to upload to iCloud…"
        case .queued: return "Upload queued. Reconnect and retry the same snapshot."
        case .uploaded: return "All save files are confirmed uploaded to iCloud."
        case .listing: return "Checking cloud versions…"
        case .downloading: return "Downloading the selected save…"
        case .validating: return "Checking the complete save before replacement…"
        case .awaitingRestoreConfirmation: return "Review the cloud save before restoring."
        case .restoring: return "Backing up and restoring the save…"
        case .finishing: return "Finishing safely. Wait before starting another operation."
        case .recoveryRequired: return "Save recovery required."
        case .failed: return "Save operation failed."
        case .cancelled: return "Operation cancelled."
        }
    }
}

struct SaveRecoveryStatusView: View {
    @ObservedObject private var bootstrap = SaveRecoveryBootstrap.shared
    @ObservedObject private var sync = SaveSyncCoordinator.shared
    var body: some View {
        if !bootstrap.ready || !bootstrap.blockedGames.isEmpty || !sync.engine.blockedGames.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(bootstrap.failed ? "Save recovery check failed" : bootstrap.ready ? "Save recovery required" : "Checking interrupted save restores…", systemImage: "externaldrive.badge.exclamationmark")
                if bootstrap.failed || bootstrap.ready {
                    Button("Retry Recovery") { sync.retryRecovery() }.disabled(sync.isBusy)
                } else { ProgressView() }
            }
            .font(.subheadline).padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityIdentifier("saveSync.recovery")
        }
    }
}
