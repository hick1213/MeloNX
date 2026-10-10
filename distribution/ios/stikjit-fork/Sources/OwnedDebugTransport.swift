// SPDX-License-Identifier: MPL-2.0
// MeloNX adaptation: a pinned Rust runtime exclusively owns the debug transport.
import Foundation
@_implementationOnly import MeloNXOwnedJIT

public final class StikJITCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var interruptedDiagnostic = false
    private weak var transport: OwnedDebugTransport?
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if transport?.cancelOwnedRuntime() == true { interruptedDiagnostic = true }
    }
    fileprivate func attach(_ transport: OwnedDebugTransport) {
        lock.lock(); defer { lock.unlock() }
        self.transport = transport
        if cancelled, transport.cancelOwnedRuntime() { interruptedDiagnostic = true }
    }
    fileprivate func detach(_ transport: OwnedDebugTransport) {
        lock.lock(); defer { lock.unlock() }
        if self.transport === transport { self.transport = nil }
    }
    /// Development proof helper: blocks on an owned runtime until cancel, then joins it.
    public func runIsolatedDiagnostic() throws {
        let transport = try OwnedDebugTransport(diagnostic: self)
        do { _ = try transport.send("WAIT") }
        catch {
            try transport.closeAndWait()
            if case OwnedDebugError.cancelled = error {
                lock.lock(); let observed = interruptedDiagnostic; lock.unlock()
                guard observed else { throw OwnedDebugError.transport }
                return
            }
            throw error
        }
        try transport.closeAndWait()
        throw OwnedDebugError.transport // A diagnostic must end by cancellation.
    }
}

enum OwnedDebugError: Error { case cancelled, transport, teardown }

final class OwnedDebugTransport {
    private var handle: OpaquePointer?
    private let cancellation: StikJITCancellation
    init(pairingFile: URL, configuration: StikJIT.Configuration, cancellation: StikJITCancellation) throws {
        self.cancellation = cancellation
        let data = try Data(contentsOf: pairingFile)
        guard !data.isEmpty, data.count <= 1_048_576 else { throw OwnedDebugError.transport }
        handle = data.withUnsafeBytes { buffer in
            configuration.deviceAddress.withCString {
                melonx_owned_debug_new(buffer.bindMemory(to: UInt8.self).baseAddress, data.count, $0, configuration.rsdPort)
            }
        }
        guard handle != nil else { throw OwnedDebugError.transport }
        cancellation.attach(self)
    }
    init(diagnostic cancellation: StikJITCancellation) throws {
        self.cancellation = cancellation
        handle = melonx_owned_debug_diagnostic_new()
        guard handle != nil else { throw OwnedDebugError.transport }
        cancellation.attach(self)
    }
    /// Called only while the cancellation controller holds its lifetime lock.
    fileprivate func cancelOwnedRuntime() -> Bool {
        guard let handle else { return false }
        return melonx_owned_debug_cancel(handle) == 1
    }
    private func exchange(_ text: String, mode: UInt8) throws -> String {
        guard let handle else { throw OwnedDebugError.transport }
        var response: UnsafeMutablePointer<CChar>?
        let status = text.withCString { melonx_owned_debug_command(handle, mode, $0, &response) }
        defer { melonx_owned_debug_string_free(response) }
        if status == 2 { throw OwnedDebugError.cancelled }
        guard status == 0 else { throw OwnedDebugError.transport }
        return response.map { String(cString: $0) } ?? ""
    }
    func send(_ command: String) throws -> String { try exchange(command, mode: 0) }
    func sendRaw(_ bytes: ArraySlice<UInt8>) throws {
        guard let text = String(bytes: bytes, encoding: .utf8), !bytes.contains(0) else { throw OwnedDebugError.transport }
        _ = try exchange(text, mode: 1)
    }
    func readResponse() throws -> String { try exchange("", mode: 2) }
    func closeAndWait() throws {
        guard let handle else { return }
        // Wait for any cancellation call, remove its access, THEN join/free.
        // Commands run only on the helper's serial worker; no concurrent command free.
        cancellation.detach(self)
        let status = melonx_owned_debug_finish(handle)
        melonx_owned_debug_free(handle)
        self.handle = nil
        guard status == 0 else { throw OwnedDebugError.teardown }
    }
    deinit { try? closeAndWait() }
}
