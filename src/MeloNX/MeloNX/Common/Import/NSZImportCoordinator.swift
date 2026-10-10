import Foundation
import Combine
import MeloNXImportCore

@MainActor final class NSZImportCoordinator: ObservableObject {
    static let shared = NSZImportCoordinator()
    private let queue = NSZImportQueue()
    var engine: NSZImportEngine { queue.engine }
    private var operationID: UUID?
    private var worker: NSZNativeWorker?
    private var task: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private(set) var sourceName = ""
    private(set) var packageKind = 0
    var isBusy: Bool { task != nil }
    var phase: NSZImportPhase { engine.phase }
    var completedBytes: Int64 { engine.completedBytes }
    var totalBytes: Int64 { engine.totalBytes }
    private init() { engine.onChange = { [weak self] in self?.objectWillChange.send() } }

    // Synchronous acquisition is essential: the picker releases its own scope after this method returns.
    func begin(source url: URL, target: URL, kind: Int, applicationID: UInt64?, onImported: @escaping @MainActor (NSZImportedFile) -> Void) {
        begin(urls: [url], target: target, kind: kind, applicationID: applicationID) { result in
            if case .success(let files) = result, let file = files.first { onImported(file) }
        }
    }
    func begin(urls: [URL], target: URL, kind: Int, applicationID: UInt64?, completion: @escaping @MainActor (Result<[NSZImportedFile], Error>) -> Void) {
        guard !isBusy, queue.canStart, !urls.isEmpty, urls.count <= 32 else {
            AppAlerts.showSyncAlert(title: "NSZ Import", message: NSZNativeFailure(code: "busy").localizedDescription)
            completion(.failure(NSZNativeFailure(code: "busy")))
            return
        }
        let leases = urls.map { NSZSourceLease(url: $0) }
        packageKind = kind
        let ids = urls.map { _ in UUID() }
        let workers = zip(urls, zip(ids, leases)).map { url, item in
            NSZNativeWorker(request: NSZNativeRequest(id: item.0, source: url.path, targetRoot: target.path,
                outputName: url.deletingPathExtension().lastPathComponent + ".nsp", kind: kind,
                applicationId: applicationID.map { String(format: "%016llx", $0) }), source: item.1)
        }
        sourceName = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) NSZ files"
        task = Task {
            defer { leases.forEach { $0.release() } }
            poller = Task { [weak self] in
                while !Task.isCancelled, let self, self.isBusy {
                    if let index = workers.firstIndex(where: { !$0.hasEnded }), let p = workers[index].progress() {
                        self.worker = workers[index]; self.operationID = ids[index]
                        let phase: NSZImportPhase = [0: .preparing, 1: .converting, 2: .validating, 3: .committing][Int(p.phase)] ?? .stopping
                        self.engine.updateProgress(id: ids[index], phase: phase, completed: p.completed, total: p.total)
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            let result = await queue.importFiles(workers: workers, ids: ids)
            poller?.cancel(); poller = nil; self.worker = nil; operationID = nil; task = nil
            objectWillChange.send()
            if let result { completion(.success(result)) }
            else if !Task.isCancelled, engine.phase == .failed {
                let error = engine.error ?? NSZNativeFailure(code: "import_failed")
                AppAlerts.showSyncAlert(title: "NSZ Import Failed", message: error.localizedDescription)
                completion(.failure(error))
            } else { completion(.failure(CancellationError())) }
        }
        objectWillChange.send()
    }
    func cancel() {
        guard isBusy else { return }
        queue.cancel()
        // Covers cancellation before the async engine starts and installs its worker.
        worker?.cancel()
        task?.cancel()
    }
}
