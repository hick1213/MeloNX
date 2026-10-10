// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Madeira JITBuiltInHost.swift; see distribution/legal/Madeira-JIT-EXCEPTION.md.
import Darwin
import Foundation
import CoreFoundation
import ObjectiveC
import MeloNXJITCore

@objc private protocol NSExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}
@objc private protocol NSExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
    @objc(cancelExtensionRequestWithIdentifier:)
    func cancelExtensionRequest(withIdentifier identifier: NSUUID)
}

@MainActor final class JITExtensionHost: JITHelperStarting {
    static let shared = JITExtensionHost()
    private var running: [ExtensionJITSession] = []
    static var unavailableReason: String? {
#if targetEnvironment(simulator)
        return JITTransportError.unavailable.localizedDescription
#else
        guard #available(iOS 26, *), getenv("LC_HOME_PATH") == nil else {
            return JITTransportError.unavailable.localizedDescription
        }
        return nil
#endif
    }
    static var tracing: Bool? {
        switch melonx_jit_tracing_state() { case 0: return false; case 1: return true; default: return nil }
    }
    func start(_ request: JITRequest) throws -> any JITHelperSession {
        guard Self.unavailableReason == nil else { throw JITTransportError.unavailable }
        running.removeAll { $0.canRelease(traced: Self.tracing) }
        guard running.isEmpty else { throw JITValidationError.busy }
        _ = try request.validated()
        guard let identifier = JITHelperLocation.identifier(in: Bundle.main.builtInPlugInsURL) else {
            throw JITTransportError.missingHelper
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else { throw JITTransportError.unavailable }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: NSExtensionClassShim.self)
        let found = try factory.extension(withIdentifier: identifier)
        let helperURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent(JITHelperLocation.file)
        let info = helperURL.flatMap { Bundle(url: $0)?.infoDictionary } ?? [:]
        let session = ExtensionJITSession(found: found, request: request,
                                         ownedCancellation: JITHelperCapability(info: info).hasOwnedCancellation)
        running.append(session)
        session.begin(data: try JSONEncoder().encode(request))
        return session
    }
}

@MainActor private final class ExtensionJITSession: JITHelperSession {
    let operationID: UUID
    private let object: AnyObject
    private let shim: NSExtensionShim
    private var requestID: NSUUID?
    private(set) var helperPID: Int32?
    private var terminal: JITHelperTerminal
    private var completedWorker = false
    private let ownedCancellation: Bool
    private var cancellationPump: Task<Void, Never>?
    private var cancellationRequested = false
    private var waiters: [CheckedContinuation<JITReply, Error>] = []

    init(found: AnyObject, request: JITRequest, ownedCancellation: Bool) {
        self.ownedCancellation = ownedCancellation
        object = found
        shim = unsafeBitCast(found, to: NSExtensionShim.self)
        operationID = request.operationID
        terminal = JITHelperTerminal(operationID: request.operationID)
    }
    var workerHasEnded: Bool? {
        if completedWorker { return true }
        guard let pid = helperPID, pid > 0 else { return nil }
        if kill(pid, 0) == 0 { return false }
        return errno == ESRCH ? true : nil
    }
    func canRelease(traced: Bool?) -> Bool {
        terminal.canRelease(workerEnded: workerHasEnded == true, traced: traced)
    }
    func requestCancellation() throws {
        cancellationRequested = true
        if ownedCancellation {
            postOwnedCancellation()
            if cancellationPump == nil {
                cancellationPump = Task { [weak self] in
                    // Repost across the short registration race; only this nonce
                    // can cancel this worker, never a retry's worker.
                    for _ in 0..<150 {
                        guard let self, !self.completedWorker else { return }
                        self.postOwnedCancellation()
                        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    }
                }
            }
            return
        }
        guard let requestID else { return } // legacy diagnostic only.
        let selector = NSSelectorFromString("cancelExtensionRequestWithIdentifier:")
        guard let cls = object_getClass(object), let method = class_getInstanceMethod(cls, selector),
              method_getNumberOfArguments(method) == 3 else { throw JITTransportError.cancellationUnavailable }
        // Validate the actual runtime ABI before invoking this private selector.
        let returnType = method_copyReturnType(method)
        guard let argumentType = method_copyArgumentType(method, 2) else {
            free(returnType)
            throw JITTransportError.cancellationUnavailable
        }
        defer { free(returnType); free(argumentType) }
        guard returnType.pointee == 118, argumentType.pointee == 64 else { throw JITTransportError.cancellationUnavailable }
        shim.cancelExtensionRequest(withIdentifier: requestID)
    }
    func terminalResult() async throws -> JITReply {
        if let result = terminal.result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func begin(data: Data) {
        shim.setRequestCompletionBlock { [weak self] _, items in
            let data = (items?.first as? NSExtensionItem)?.userInfo?[JITReply.itemKey] as? Data
            DispatchQueue.main.async {
                guard let self else { return }
                if let data {
                    self.completedWorker = self.terminal.acceptWorkerCompletion(data)
                } else { self.terminal.fail(.invalidResponse) }
                self.deliver()
            }
        }
        shim.setRequestCancellationBlock { [weak self] _, _ in
            DispatchQueue.main.async { self?.failed(.cancelled) }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async { self?.failed(.interrupted) }
        }
        let item = NSExtensionItem()
        item.userInfo = [JITRequest.itemKey: data]
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] id in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let id else { self.completedWorker = true; self.failed(.missingHelper); return }
                self.requestID = id
                let pid = self.shim.pid(forRequestIdentifier: id)
                self.helperPID = pid > 0 ? pid : nil
                print("[jit-helper] started pid=\(pid)")
                if self.cancellationRequested {
                    do { try self.requestCancellation() }
                    catch { self.failed(.cancellationUnavailable) }
                }
            }
        }
    }
    private func postOwnedCancellation() {
        let name = JITCancellationSignal.name(for: operationID) as CFString
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name), nil, nil, true)
    }
    private func failed(_ error: JITTransportError) {
        terminal.fail(error)
        deliver()
    }
    private func deliver() {
        guard let result = terminal.result else { return }
        if completedWorker { cancellationPump?.cancel(); cancellationPump = nil }
        let callbacks = waiters
        waiters.removeAll()
        callbacks.forEach { $0.resume(with: result) }
    }
}
