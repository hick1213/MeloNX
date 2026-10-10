import Foundation

public enum NSZImportPhase: String, Sendable {
    case idle, preparing, converting, validating, committing, stopping, succeeded, failed, cancelled
}
public struct NSZImportedFile: Sendable {
    public let operationID: UUID
    public let path: String
    public let kind: Int
    public let applicationID: UInt64
    public init(operationID: UUID, path: String, kind: Int, applicationID: UInt64) {
        self.operationID = operationID; self.path = path; self.kind = kind; self.applicationID = applicationID
    }
}
@MainActor public protocol NSZImportWorker: AnyObject {
    var hasEnded: Bool { get }
    func run() async throws -> NSZImportedFile
    func cancel()
}
