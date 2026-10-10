import Foundation
import MeloNXImportCore

nonisolated final class NSZSourceLease: @unchecked Sendable {
    let url: URL
    private let access: NSZAccessLease
    private let coordinator = NSFileCoordinator(filePresenter: nil)
    init(url: URL) {
        self.url = url
        access = NSZAccessLease(start: { url.startAccessingSecurityScopedResource() }, stop: { url.stopAccessingSecurityScopedResource() })
    }
    func coordinate<T>(_ body: (URL) throws -> T) throws -> T {
        var result: Result<T, Error>?
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { coordinatedURL in
            result = Result { try body(coordinatedURL) }
        }
        if let error { throw error }
        guard let result else { throw NSZNativeFailure(code: "source_unavailable") }
        return try result.get()
    }
    func cancelCoordination() { coordinator.cancel() }
    func release() { access.release() }
}
