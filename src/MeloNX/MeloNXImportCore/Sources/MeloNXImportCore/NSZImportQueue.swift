import Foundation

@MainActor public final class NSZImportQueue {
    public let engine = NSZImportEngine()
    public var onImported: (@MainActor (NSZImportedFile) throws -> Void)?
    public private(set) var completedFiles: [NSZImportedFile] = []
    public private(set) var error: Error?
    public var canStart: Bool { !active }
    private var active = false
    private var cancelled = false
    private var currentID: UUID?
    public init() {}
    public func importFiles(workers: [any NSZImportWorker], ids: [UUID]) async -> [NSZImportedFile]? {
        guard canStart, !workers.isEmpty, workers.count == ids.count, workers.count <= 32,
              Set(ids).count == ids.count else { return nil }
        active = true; cancelled = false; completedFiles = []; error = nil
        defer { active = false; currentID = nil }
        var results: [NSZImportedFile] = []
        for (worker, id) in zip(workers, ids) {
            guard !cancelled, !Task.isCancelled else { return nil }
            currentID = id
            guard let result = await engine.importFile(worker: worker, id: id), !cancelled, !Task.isCancelled else {
                error = engine.error; return nil
            }
            results.append(result)
            completedFiles.append(result)
            do { try onImported?(result) }
            catch { self.error = error; return nil }
        }
        return results
    }
    public func cancel() {
        guard active else { return }
        cancelled = true
        if let currentID { engine.cancel(id: currentID) }
    }
}
