import Foundation

public final class NSZAccessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var acquired: Bool
    private let stop: () -> Void
    public init(start: () -> Bool, stop: @escaping () -> Void) { acquired = start(); self.stop = stop }
    public func release() {
        lock.lock(); defer { lock.unlock() }
        if acquired { acquired = false; stop() }
    }
    deinit { release() }
}

public final class NSZHandleLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var ended = false
    private var cancelled = false
    public init() {}
    public func install(_ handle: UnsafeMutableRawPointer, cancel: (UnsafeMutableRawPointer) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended, self.handle == nil else { return false }
        self.handle = handle
        if cancelled { cancel(handle) }
        return true
    }
    public func borrow<T>(_ body: (UnsafeMutableRawPointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        return body(handle)
    }
    public func cancel(_ body: (UnsafeMutableRawPointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let handle { body(handle) }
    }
    public func finish<T>(_ body: (UnsafeMutableRawPointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        ended = true
        guard let handle else { return nil }
        self.handle = nil
        return body(handle)
    }
}
