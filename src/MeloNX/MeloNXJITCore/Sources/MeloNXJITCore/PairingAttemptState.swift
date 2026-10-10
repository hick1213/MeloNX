import Foundation

/// A cancelled native accept still owns its resources until it returns.
public struct PairingAttemptState: Sendable {
    public private(set) var activeID: UUID?
    public private(set) var isCancelled = false
    public init() {}
    public mutating func begin() throws -> UUID {
        guard activeID == nil else { throw JITValidationError.busy }
        let id = UUID()
        activeID = id
        isCancelled = false
        return id
    }
    public func ownsCallback(id: UUID) -> Bool { activeID == id }
    public mutating func cancel(id: UUID) {
        guard activeID == id else { return }
        isCancelled = true
    }
    /// Returns permission to store a successful result, not proof of network success.
    public mutating func finish(id: UUID) -> Bool {
        guard activeID == id else { return false }
        let store = !isCancelled
        activeID = nil
        isCancelled = false
        return store
    }
}
