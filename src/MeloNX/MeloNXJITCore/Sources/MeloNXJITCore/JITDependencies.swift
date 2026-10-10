import Foundation

@MainActor public protocol JITPairingStoring {
    func load() throws -> PairingRecord?
    func replace(with data: Data) throws
}

@MainActor public protocol PairingCredentialBackend {
    func read() throws -> Data?
    /// Atomically replaces the credential, retaining the previous value on failure.
    func write(_ data: Data) throws
}

public struct JITNetworkStatus: Sendable {
    public let canAttemptAuthentication: Bool
    public let reason: String?
    public init(canAttemptAuthentication: Bool, reason: String?) {
        self.canAttemptAuthentication = canAttemptAuthentication
        self.reason = reason
    }
}

public protocol JITNetworkChecking: Sendable {
    func check() async -> JITNetworkStatus
}

@MainActor public protocol JITHelperSession: AnyObject {
    var operationID: UUID { get }
    var helperPID: Int32? { get }
    var workerHasEnded: Bool? { get }
    func requestCancellation() throws
    func terminalResult() async throws -> JITReply
}
@MainActor public protocol JITHelperStarting {
    func start(_ request: JITRequest) throws -> any JITHelperSession
}

public struct JITDebuggerSnapshot: Sendable {
    public let codeSigningDebugged: Bool
    public let currentlyTraced: Bool?
    public init(codeSigningDebugged: Bool, currentlyTraced: Bool?) {
        self.codeSigningDebugged = codeSigningDebugged
        self.currentlyTraced = currentlyTraced
    }
}
public protocol JITMapping: Sendable { func initialize() async throws -> Bool }
public protocol JITClock: Sendable {
    var now: TimeInterval { get }
    func sleep(for seconds: TimeInterval) async throws
}
