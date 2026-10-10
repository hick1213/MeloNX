import Foundation
import MeloNXImportCore

nonisolated struct NSZNativeRequest: Encodable, Sendable {
    let version = 1
    let id: UUID
    var source: String
    let targetRoot: String
    let outputName: String
    let kind: Int
    let applicationId: String?
}
nonisolated private struct NSZNativeResult: Decodable {
    let version: Int
    let id: UUID
    let status: Int
    let path: String?
    let kind: Int
    let applicationId: String?
    let errorCode: String?
}
nonisolated struct NSZNativeFailure: LocalizedError {
    let code: String
    var errorDescription: String? {
        switch code {
        case "insufficient_space": return "Not enough free space to import this NSZ."
        case "missing_key": return "This package needs keys that are not installed. Import the required keys in Settings."
        case "wrong_package": return "The package does not match the selected game or content type."
        case "unsupported_package": return "The package is unsupported, mixed, or incomplete."
        case "invalid_package": return "The NSZ package failed integrity or metadata validation."
        case "busy": return "An import is already running. Wait for it to finish."
        case "source_unavailable": return "The selected file could not be read. Check that it is downloaded and available."
        case "io_failure": return "The file could not be imported. Check storage and file access."
        default: return "NSZ import failed."
        }
    }
}

@MainActor final class NSZNativeWorker: NSZImportWorker {
    private(set) var hasEnded = false
    private var hasRun = false
    private let request: NSZNativeRequest
    private let source: NSZSourceLease
    nonisolated private let lifetime = NSZHandleLifetime()
    private let queue = DispatchQueue(label: "MeloNX.NSZImport", qos: .userInitiated)
    init(request: NSZNativeRequest, source: NSZSourceLease) { self.request = request; self.source = source }
    func cancel() {
        lifetime.cancel { nsz_import_cancel($0) }
        source.cancelCoordination()
    }
    func progress() -> MeloNXNSZProgress? {
        lifetime.borrow { handle -> MeloNXNSZProgress? in
            var snapshot = MeloNXNSZProgress()
            return nsz_import_progress(handle, &snapshot) == 0 && snapshot.version == 1 ? snapshot : nil
        } ?? nil
    }
    func run() async throws -> NSZImportedFile {
        guard !hasRun else { throw NSZNativeFailure(code: "import_failed") }
        hasRun = true
        let request = request, source = source, lifetime = lifetime
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let outcome: Result<NSZImportedFile, Error> = Result {
                    try source.coordinate { url in
                        var coordinated = request; coordinated.source = url.path
                        return try Self.perform(request: coordinated, lifetime: lifetime)
                    }
                }
                _ = lifetime.finish { nsz_import_free($0) }
                source.release()
                DispatchQueue.main.async {
                    self.hasEnded = true
                    continuation.resume(with: outcome)
                }
            }
        }
    }
    nonisolated private static func perform(request: NSZNativeRequest, lifetime: NSZHandleLifetime) throws -> NSZImportedFile {
        let data = try JSONEncoder().encode(request)
        guard data.count <= 65536 else { throw NSZNativeFailure(code: "invalid_request") }
        let json = String(decoding: data, as: UTF8.self)
        var creationError: UnsafeMutablePointer<CChar>?
        let handle = json.withCString { nsz_import_create($0, &creationError) }
        let errorCode = creationError.map { String(cString: $0) }
        if let creationError { nsz_import_string_free(creationError) }
        guard let handle else { throw NSZNativeFailure(code: errorCode ?? "import_failed") }
        guard lifetime.install(handle, cancel: { nsz_import_cancel($0) }) else {
            nsz_import_free(handle); throw NSZNativeFailure(code: "import_failed")
        }
        let status = nsz_import_run(handle)
        let resultData: Data? = lifetime.finish { pointer -> Data? in
            defer { nsz_import_free(pointer) }
            guard let string = nsz_import_result(pointer) else { return nil }
            defer { nsz_import_string_free(string) }
            return Data(String(cString: string).utf8)
        } ?? nil
        if status == 1 { throw CancellationError() }
        guard let resultData, resultData.count <= 65536 else { throw NSZNativeFailure(code: "import_failed") }
        let result = try JSONDecoder().decode(NSZNativeResult.self, from: resultData)
        guard result.version == 1, result.id == request.id, result.status == status else { throw NSZNativeFailure(code: "import_failed") }
        guard status == 0 else { throw NSZNativeFailure(code: result.errorCode ?? "import_failed") }
        guard let path = result.path, path.hasPrefix("/"), let value = result.applicationId,
              value.count == 16, let application = UInt64(value, radix: 16),
              NSZImportRouting.accepts(kind: result.kind, applicationID: application, expectedKind: request.kind,
                                       expectedApplicationID: request.applicationId.flatMap { UInt64($0, radix: 16) }) else {
            throw NSZNativeFailure(code: "wrong_package")
        }
        return NSZImportedFile(operationID: request.id, path: path, kind: result.kind, applicationID: application)
    }
}
