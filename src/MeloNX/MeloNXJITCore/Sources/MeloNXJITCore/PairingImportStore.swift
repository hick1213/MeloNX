import Foundation

@MainActor public final class PairingImportStore: JITPairingStoring {
    private let backend: any PairingCredentialBackend
    public init(backend: any PairingCredentialBackend) { self.backend = backend }
    public func load() throws -> PairingRecord? {
        guard let data = try backend.read() else { return nil }
        return try PairingRecord(validating: data)
    }
    public func replace(with data: Data) throws {
        let record = try PairingRecord(validating: data)
        try backend.write(record.data)
    }
}
