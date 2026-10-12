//
//  DLCManagerSheet.swift
//  MeloNX
//
//  Created by Stossy11 on 1/6/2026.
//

import SwiftUI
import MeloNXOperationCore
import MeloNXImportCore
import UniformTypeIdentifiers
import Combine

struct DLCManagerSheet: View {
    @EnvironmentObject var ryujinxController: RyujinxController
    @State private var dlcs: [DLCItem] = []
    var game: GameInfo?
    @State private var jsonURL: URL? = nil
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var nszImport = NSZImportCoordinator.shared
    @State private var ownsNSZImport = false
    @State private var importError: String?
    @State private var importNote: String?
    @State private var needsSaveRetry = false
    
    struct DLCItem: Identifiable {
        let id = UUID()
        let url: URL
        let filename: String
        let relativePath: String
        var ncaList: [DownloadableContentNca]
        
        var isEnabled: Bool
        
        init(url: URL, filename: String, relativePath: String, ncaList: [DownloadableContentNca], isEnabled: Bool = false) {
            self.url = url
            self.filename = filename
            self.relativePath = relativePath
            self.ncaList = ncaList
            self.isEnabled = isEnabled
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                if let importError {
                    Section {
                        Text(importError).foregroundStyle(.red)
                        if needsSaveRetry { Button("重试保存列表", action: retrySaveJSON) }
                    }
                }
                if let importNote { Section { Text(importNote).foregroundStyle(.secondary) } }
                if dlcs.isEmpty {
                    emptyStateView
                } else {
                    ForEach(dlcs) { dlc in
                        dlcRow(dlc)
                    }
                    .onDelete(perform: removeDLCs)
                }
            }
            .navigationTitle("\(game?.titleName ?? "Game") DLCs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        FileImporterManager.shared.importFiles(
                            types: [.item],
                            allowMultiple: true,
                            completion: handleFileImport
                        )
                    } label: {
                        Label("Add DLC", systemImage: "plus")
                    }
                }
            }
            .onAppear {
                loadData()
            }
            .sheet(isPresented: Binding(get: { ownsNSZImport && nszImport.isBusy && nszImport.packageKind == 2 }, set: { if !$0 { nszImport.cancel() } })) {
                NSZImportProgressView()
            }
        }
    }
    
    private var emptyStateView: some View {
        Group {
            if #available(iOS 17, *) {
                ContentUnavailableView(
                    "No DLCs Found",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Tap the + button to add game DLCs.")
                )
            } else {
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No DLCs Found")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Tap the + button to add game DLCs.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
            }
        }
    }
    
    private func dlcRow(_ dlc: DLCItem) -> some View {
        Group {
            if #available(iOS 15, *) {
                dlcRowNew(dlc)
            } else {
                dlcRowOld(dlc)
            }
        }
    }
    
    @available(iOS 15, *)
    private func dlcRowNew(_ dlc: DLCItem) -> some View {
        Button {
            toggleDLC(dlc)
        } label: {
            HStack {
                Text(dlc.filename)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: dlc.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(dlc.isEnabled ? .primary : .secondary)
                    .imageScale(.large)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                if let index = dlcs.firstIndex(where: { $0.relativePath == dlc.relativePath }) {
                    removeDLC(at: IndexSet(integer: index))
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private func dlcRowOld(_ dlc: DLCItem) -> some View {
        Button {
            toggleDLC(dlc)
        } label: {
            HStack {
                Text(dlc.filename)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: dlc.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(dlc.isEnabled ? .primary : .secondary)
                    .imageScale(.large)
            }
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button {
                if let index = dlcs.firstIndex(where: { $0.relativePath == dlc.relativePath }) {
                    removeDLC(at: IndexSet(integer: index))
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private func loadData() {
        guard let game = game else { return }
        
        jsonURL = URL.documentsDirectory
            .appendingPathComponent("games")
            .appendingPathComponent(game.titleId)
            .appendingPathComponent("dlc.json")
        
        loadJSON()
    }
    
    private func loadJSON() {
        guard let jsonURL = jsonURL else { return }
        
        do {
            guard FileManager.default.fileExists(atPath: jsonURL.path) else {
                createDefaultJSON()
                return
            }
            
            let data = try Data(contentsOf: jsonURL)
            let containers = try JSONDecoder().decode([DownloadableContentContainer].self, from: data)
            
            dlcs = containers.compactMap { container in
                let url = URL.documentsDirectory.appendingPathComponent(container.containerPath)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let isEnabled = container.downloadableContentNcaList.first?.enabled ?? false
                return DLCItem(
                    url: url,
                    filename: url.lastPathComponent,
                    relativePath: container.containerPath,
                    ncaList: container.downloadableContentNcaList,
                    isEnabled: isEnabled
                )
            }
        } catch {
            print("Failed to read DLC JSON: \(error)")
            createDefaultJSON()
        }
    }
    
    private func createDefaultJSON() {
        guard let jsonURL = jsonURL else { return }
        
        do {
            try FileManager.default.createDirectory(
                at: jsonURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode([DownloadableContentContainer]())
            try data.write(to: jsonURL, options: .atomic)
            needsSaveRetry = false
            dlcs = []
        } catch {
            print("Failed to create default DLC JSON: \(error)")
        }
    }
    
    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            importError = nil
            importNote = nil
            if urls.contains(where: { $0.pathExtension.lowercased() == "nsz" }) {
                guard let game, let applicationID = UInt64(game.titleId, radix: 16),
                      urls.allSatisfy({ $0.pathExtension.lowercased() == "nsz" }) else {
                    AppAlerts.showSyncAlert(title: "NSZ Import", message: "Select NSZ DLCs separately from other formats.")
                    return
                }
                ownsNSZImport = true
                ryujinxController.beginNSZImport(urls: urls, intent: .dlc(applicationID: applicationID), onImported: { file in
                    try NSZAddonRegistration.dlc(file, applicationID: applicationID)
                    loadJSON(); ryujinxController.loadGames()
                }) { _ in ownsNSZImport = false }
                return
            }
            guard let operation = LocalOperations.beginImport(gameID: game.flatMap { UInt64($0.titleId, radix: 16) }, onFailure: { importError = $0 }) else { return }
            defer { try? operation.finish(workerHasEnded: true) }
            var newDLCs: [DLCItem] = []
            
            for selectedURL in urls {
                guard let game = game else {
                    continue
                }

                let hasSecurityScope = selectedURL.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope {
                        selectedURL.stopAccessingSecurityScopedResource()
                    }
                }
                
                do {
                    
                    
                    let filename = selectedURL.lastPathComponent
                    let relativePath = "dlc/\(game.titleId)/\(filename)"
                    let destinationURL = URL.documentsDirectory.appendingPathComponent(relativePath)
                    
                    guard !dlcs.contains(where: { $0.relativePath == relativePath }) else {
                        importError = "此 DLC 已经添加：\(filename)"
                        continue
                    }
                    
                    let ncaList = Ryujinx.getDlcNcaList(titleId: game.titleId, path: selectedURL.path)
                    try AddonPackageCopy.copy(source: selectedURL, destination: destinationURL) {
                        guard !ncaList.isEmpty else {
                            throw NSError(domain: "MeloNXAddon", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                "未找到属于当前游戏的 DLC。若这是 [UPD] 更新包，请从“更新管理”导入；也请确认文件完整且所需 keys 已安装。"])
                        }
                    }
                    
                    newDLCs.append(DLCItem(
                        url: destinationURL,
                        filename: filename,
                        relativePath: relativePath,
                        ncaList: ncaList,
                        isEnabled: false
                    ))
                } catch {
                    importError = "\(selectedURL.lastPathComponent)：\(error.localizedDescription)"
                }
            }
            
            guard !newDLCs.isEmpty else { return }
            
            if !dlcs.contains(where: { $0.isEnabled }) {
                newDLCs[0].isEnabled = true
            }
            
            dlcs.append(contentsOf: newDLCs)
            saveJSON()
            if importError == nil { importNote = "已添加 \(newDLCs.count) 个 DLC 文件。" }
            ryujinxController.loadGames()
            
        case .failure(let error):
            let failure = error as NSError
            if failure.domain != "FileImporterManager" || failure.code != 2 { importError = error.localizedDescription }
        }
    }
    
    private func toggleDLC(_ dlc: DLCItem) {
        guard let operation = LocalOperations.beginImport(gameID: game.flatMap { UInt64($0.titleId, radix: 16) }, onFailure: { importError = $0 }) else { return }
        defer { try? operation.finish(workerHasEnded: true) }
        guard let index = dlcs.firstIndex(where: { $0.relativePath == dlc.relativePath }) else { return }
        dlcs[index].isEnabled.toggle()
        saveJSON()
    }
    
    private func removeDLCs(at offsets: IndexSet) {
        offsets.forEach { removeDLC(at: IndexSet(integer: $0)) }
    }
    
    private func removeDLC(at indexSet: IndexSet) {
        guard let operation = LocalOperations.beginImport(gameID: game.flatMap { UInt64($0.titleId, radix: 16) }, onFailure: { importError = $0 }) else { return }
        defer { try? operation.finish(workerHasEnded: true) }
        guard let index = indexSet.first else { return }
        
        let dlcToRemove = dlcs[index]
        
        do {
            try FileManager.default.removeItem(at: dlcToRemove.url)
            dlcs.remove(at: index)
            saveJSON()
            ryujinxController.loadGames()
        } catch {
            print("Failed to remove DLC: \(error)")
        }
    }
    
    private func retrySaveJSON() {
        guard let operation = LocalOperations.beginImport(gameID: game.flatMap { UInt64($0.titleId, radix: 16) }, onFailure: { importError = $0 }) else { return }
        defer { try? operation.finish(workerHasEnded: true) }
        importError = nil
        saveJSON()
    }

    private func saveJSON() {
        guard let jsonURL = jsonURL else { return }

        do {
            let containers = dlcs.map { dlc in
                DownloadableContentContainer(
                    containerPath: dlc.relativePath,
                    downloadableContentNcaList: dlc.ncaList.map { nca in
                        var mutableNca = nca
                        mutableNca.enabled = dlc.isEnabled
                        return mutableNca
                    }
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(containers)
            try data.write(to: jsonURL, options: .atomic)
            needsSaveRetry = false
        } catch {
            needsSaveRetry = true
            importError = "导入列表保存失败：\(error.localizedDescription)"
        }
    }
}
