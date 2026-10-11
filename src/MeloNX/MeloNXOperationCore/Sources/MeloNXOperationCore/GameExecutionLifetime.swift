/// UI may request exit, but only the returning native worker completes a run.
public struct GameExecutionLifetime: Sendable {
    private enum State: Sendable { case idle, running, stopping }
    private var state = State.idle
    public init() {}
    public var nativeActive: Bool { state != .idle }
    public var isStopping: Bool { state == .stopping }
    @discardableResult public mutating func begin() -> Bool {
        guard state == .idle else { return false }
        state = .running; return true
    }
    @discardableResult public mutating func requestStop() -> Bool {
        guard state == .running else { return false }
        state = .stopping; return true
    }
    public mutating func workerEnded() { state = .idle }
}
