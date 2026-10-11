import Foundation

private final class CloudCoordination: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    private let lock = NSLock()
    private var timedOut = false
    func expire() { lock.lock(); timedOut = true; lock.unlock(); coordinator.cancel() }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
}


public final class CloudFileCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeloNX.SaveSync.CloudFiles", qos: .utility)
    public init() {}
    public func coordinate<T: Sendable>(_ url: URL, writing: Bool, timeout: TimeInterval = 30,
                                        body: @escaping @Sendable (URL) throws -> T) async throws -> T {
        guard timeout.isFinite, timeout > 0, timeout <= 3600 else { throw SaveSyncError.cloudUnavailable }
        let session = CloudCoordination()
        let identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: nil) { _ in session.coordinator.cancel() }
        defer { NotificationCenter.default.removeObserver(identityObserver) }
        let deadline = Task { try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000)); session.expire() }
        defer { deadline.cancel() }
        let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    var coordinationError: NSError?, value: Result<T, Error>?
                    let accessor: (URL) -> Void = { url in value = Result { try body(url) } }
                    if writing { session.coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
                    else { session.coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError, byAccessor: accessor) }
                    if session.expired { continuation.resume(throwing: SaveSyncError.queued) }
                    else if let coordinationError { continuation.resume(throwing: coordinationError) }
                    else if let value { continuation.resume(with: value) }
                    else { continuation.resume(throwing: SaveSyncError.cloudUnavailable) }
                }
            }
        } onCancel: { session.coordinator.cancel() }
        try Task.checkCancellation()
        return result
    }
}
