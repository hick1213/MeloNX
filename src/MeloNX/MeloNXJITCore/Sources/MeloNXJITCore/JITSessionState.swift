import Foundation

public enum JITPhase: String, Codable, Sendable {
    case idle, needsSetup, checkingNetwork, preparing, attaching, mapping
    case stopping, ready, failed, cancelled
}

/// State transitions never certify teardown from an IPC cancellation callback alone.
public struct JITSessionState: Sendable {
    public private(set) var phase: JITPhase = .idle
    public private(set) var activeID: UUID?
    public private(set) var pendingLaunchID: UUID?
    private var cancelled = false

    public init() {}
    public var canRetry: Bool { activeID == nil }
    public var allowedLaunchID: UUID? { phase == .ready ? pendingLaunchID : nil }

    public mutating func begin(pid: Int32, launchID: UUID?) throws -> UUID {
        guard pid > 0 else { throw JITValidationError.invalidPID }
        guard activeID == nil else { throw JITValidationError.busy }
        let id = UUID()
        activeID = id
        pendingLaunchID = launchID
        cancelled = false
        phase = .checkingNetwork
        return id
    }

    @discardableResult
    public mutating func transition(id: UUID, to next: JITPhase) -> Bool {
        guard activeID == id, !cancelled, phase != .stopping,
              [.needsSetup, .checkingNetwork, .preparing, .attaching, .mapping].contains(next)
        else { return false }
        phase = next
        return true
    }

    public mutating func cancel(id: UUID) {
        guard activeID == id else { return }
        cancelled = true
        pendingLaunchID = nil
        phase = .stopping
    }

    public mutating func complete(id: UUID, mapped: Bool, helperEnded: Bool, tracing: Bool?) {
        guard activeID == id else { return }
        guard helperEnded, tracing == false else {
            phase = .stopping
            return
        }
        activeID = nil
        if cancelled {
            phase = .cancelled
        } else if mapped {
            phase = .ready
        } else {
            phase = .failed
            pendingLaunchID = nil
        }
    }
}
