import Foundation
import MeloNXSaveSyncCore

@MainActor private final class CloudGatheringState { var finished = false }

@MainActor enum CloudTransferObserver {
    /// Metadata notifications drive refreshes. A timer enforces the deadline and
    /// cancellation even when iCloud is offline and emits no status notification.
    static func wait<T: Sendable>(root: URL, timeout: TimeInterval = 30, expiry: SaveSyncError,
                                 evaluate: @MainActor (NSMetadataQuery, Bool) async throws -> T?) async throws -> T {
        let query = NSMetadataQuery()
        let gathering = CloudGatheringState()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path + "/")
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let center = NotificationCenter.default
        let observations = [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate].map { name in
            center.addObserver(forName: name, object: query, queue: .main) { _ in
                Task { @MainActor in
                    if name == .NSMetadataQueryDidFinishGathering { gathering.finished = true }
                    pair.continuation.yield(())
                }
            }
        }
        let identity = center.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { _ in pair.continuation.yield(()) }
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in pair.continuation.yield(()) }
        defer {
            query.stop(); timer.invalidate(); observations.forEach(center.removeObserver)
            center.removeObserver(identity); pair.continuation.finish()
        }
        guard query.start() else { throw SaveSyncError.cloudUnavailable }
        pair.continuation.yield(())
        let deadline = Date().addingTimeInterval(timeout)
        for await _ in pair.stream {
            try Task.checkCancellation()
            if let value = try await evaluate(query, gathering.finished) { return value }
            guard Date() < deadline else { throw expiry }
        }
        throw CancellationError()
    }
    nonisolated static func fileStates(root: URL, required: Set<String>) throws -> [String: CloudFileState] {
        var states: [String: CloudFileState] = [:]
        for relative in required {
            var url = try SnapshotLocalVerifier.contained(root, relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            url.removeAllCachedResourceValues()
            let values = try url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey])
            let error = values.ubiquitousItemUploadingError ?? values.ubiquitousItemDownloadingError
            let typed: SaveSyncError? = error.map { ($0 as NSError).code == CocoaError.Code.ubiquitousFileUbiquityServerNotAvailable.rawValue ? .queued : .cloudUnavailable }
            let quota = (error as NSError?)?.code == CocoaError.Code.ubiquitousFileNotUploadedDueToQuota.rawValue
            states[relative] = CloudFileState(uploaded: values.ubiquitousItemIsUploaded == true,
                downloaded: values.ubiquitousItemDownloadingStatus == .current,
                conflicted: values.ubiquitousItemHasUnresolvedConflicts == true || !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty ?? true),
                error: quota ? .quota : typed)
        }
        return states
    }
}
