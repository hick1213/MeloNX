import Foundation

@MainActor public final class NSZImportEngine {
    public var onChange: (@MainActor () -> Void)?
    public private(set) var phase: NSZImportPhase = .idle
    public private(set) var completedBytes: Int64 = 0
    public private(set) var totalBytes: Int64 = 0
    public private(set) var error: Error?
    public var canStart: Bool { worker == nil }
    private var worker: (any NSZImportWorker)?
    private var operationID: UUID?
    private var cancelled = false
    public init() {}
    public func importFile(worker: any NSZImportWorker, id: UUID) async -> NSZImportedFile? {
        guard canStart else { return nil }
        self.worker = worker; operationID = id; cancelled = false; error = nil
        completedBytes = 0; totalBytes = 0; phase = .preparing; onChange?()
        if Task.isCancelled { cancel(id: id) }
        var result: NSZImportedFile?
        do {
            result = try await withTaskCancellationHandler(operation: { try await worker.run() }, onCancel: {
                Task { @MainActor [weak self] in self?.cancel(id: id) }
            })
        } catch { self.error = error }
        if !worker.hasEnded {
            phase = .stopping; onChange?()
            while !worker.hasEnded { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        if Task.isCancelled { cancel(id: id) }
        if cancelled || error is CancellationError || error is NSZImportCancellation {
            result = nil; phase = .cancelled
        } else if error != nil || result?.operationID != id {
            result = nil; phase = .failed
        } else { phase = .succeeded }
        self.worker = nil; operationID = nil; onChange?()
        return result
    }
    public func cancel(id: UUID) {
        guard operationID == id, let worker else { return }
        cancelled = true; phase = .stopping; worker.cancel(); onChange?()
    }
    public func updateProgress(id: UUID, phase: NSZImportPhase, completed: Int64, total: Int64) {
        guard operationID == id, worker != nil, !cancelled,
              [.preparing, .converting, .validating, .committing].contains(phase) else { return }
        self.phase = phase; completedBytes = max(0, completed); totalBytes = max(completedBytes, total); onChange?()
    }
}
