import Foundation
import Combine
import MeloNXImportCore

@MainActor final class NSZImportCoordinator: ObservableObject {
    static let shared = NSZImportCoordinator()
    let engine = NSZImportEngine()
    private var operationID: UUID?
    private var worker: NSZNativeWorker?
    private var task: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private(set) var sourceName = ""
    var isBusy: Bool { task != nil }
    var phase: NSZImportPhase { engine.phase }
    var completedBytes: Int64 { engine.completedBytes }
    var totalBytes: Int64 { engine.totalBytes }
    private init() { engine.onChange = { [weak self] in self?.objectWillChange.send() } }

    // Synchronous acquisition is essential: the picker releases its own scope after this method returns.
    func begin(source url: URL, target: URL, kind: Int, applicationID: UInt64?, onImported: @escaping @MainActor (NSZImportedFile) -> Void) {
        guard !isBusy, engine.canStart else {
            AppAlerts.showSyncAlert(title: "NSZ Import", message: NSZNativeFailure(code: "busy").localizedDescription)
            return
        }
        let id = UUID(), lease = NSZSourceLease(url: url)
        let request = NSZNativeRequest(id: id, source: url.path, targetRoot: target.path,
            outputName: url.deletingPathExtension().lastPathComponent + ".nsp", kind: kind,
            applicationId: applicationID.map { String(format: "%016llx", $0) })
        let worker = NSZNativeWorker(request: request, source: lease)
        self.worker = worker; operationID = id; sourceName = url.lastPathComponent
        task = Task {
            poller = Task { [weak self] in
                while !Task.isCancelled, let self, self.operationID == id {
                    if let p = worker.progress() {
                        let phase: NSZImportPhase = [0: .preparing, 1: .converting, 2: .validating, 3: .committing][Int(p.phase)] ?? .stopping
                        self.engine.updateProgress(id: id, phase: phase, completed: p.completed, total: p.total)
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            let result = await engine.importFile(worker: worker, id: id)
            poller?.cancel(); poller = nil; self.worker = nil; operationID = nil; task = nil
            objectWillChange.send()
            if let result { onImported(result) }
            else if engine.phase == .failed {
                AppAlerts.showSyncAlert(title: "NSZ Import Failed", message: engine.error?.localizedDescription ?? "NSZ import failed.")
            }
        }
        objectWillChange.send()
    }
    func cancel() {
        guard let operationID else { return }
        engine.cancel(id: operationID)
        // Covers cancellation before the async engine starts and installs its worker.
        worker?.cancel()
        task?.cancel()
    }
}
