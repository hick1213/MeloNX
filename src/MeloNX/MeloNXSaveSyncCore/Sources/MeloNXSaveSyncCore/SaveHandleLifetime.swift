import Foundation

/// The native Run call is deliberately outside this lock. Stop/progress borrow
/// the installed handle; finish waits for all borrowers and runs only after Run.
public final class SaveHandleLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var ended = false
    private var stopped = false
    public init() {}
    public var hasEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    public func install(_ value: UnsafeMutableRawPointer, stop: (UnsafeMutableRawPointer) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended, handle == nil else { return false }
        handle = value
        if stopped { stop(value) }
        return true
    }
    public func borrow<T>(_ body: (UnsafeMutableRawPointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        return body(handle)
    }
    public func requestStop(_ stop: (UnsafeMutableRawPointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if let handle { stop(handle) }
    }
    @discardableResult public func finish<T>(_ free: (UnsafeMutableRawPointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return nil }
        defer { ended = true; handle = nil }
        return handle.map(free)
    }
}
