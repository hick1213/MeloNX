// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from MadeiraJITHelper.swift; see distribution/legal/Madeira-JIT-EXCEPTION.md.
import Foundation
import CoreFoundation
import MeloNXJITCore
import StikJIT

private enum MeloNXJITWork {
    static let queue = DispatchQueue(label: "melonx.jit-helper")
    static func handle(_ request: JITRequest, cancellation: StikJITCancellation) -> JITReply {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        func reply(_ success: Bool, _ message: String) -> JITReply {
            JITReply(operationID: request.operationID, success: success, message: message, txmPresent: StikJIT.isTXMPresent)
        }
        do {
            _ = try request.validated()
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
#if DEBUG
            if request.operation == .diagnosticWait {
                try cancellation.runIsolatedDiagnostic()
                return reply(true, "Diagnostic cancellation joined the owned worker.")
            }
#endif
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return reply(true, "Developer Disk Image cache reset.")
            }
            guard let data = request.pairingData else { throw JITValidationError.missingPairing }
            let pairingURL = root.appendingPathComponent("pairing-\(UUID().uuidString).plist")
            try data.write(to: pairingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            defer { try? manager.removeItem(at: pairingURL) }
            let configuration = StikJIT.Configuration(rsdPort: request.rsdPort ?? 49152, connectionTimeout: 5)
            switch request.operation {
            case .prepare:
                switch StikJIT.prepareDevice(pairingFile: pairingURL, paths: paths, configuration: configuration) {
                case .ready(let security):
                    return JITReply(operationID: request.operationID, success: true, message: "Device authenticated and Developer Disk Image ready.", txmPresent: security.isTXMPresent)
                case .unreachable: return reply(false, "The device service could not be authenticated. Check LocalDevVPN and the pairing file.")
                case .preparationFailed: return reply(false, "Developer Disk Image preparation failed. Check the network and retry.")
                @unknown default: return reply(false, "The JIT framework returned an unknown preparation state.")
                }
            case .enable:
                guard let pid = request.targetPID else { throw JITValidationError.invalidPID }
                try StikJIT.enableJIT(targetPID: pid, pairingFile: pairingURL, ddiPaths: paths,
                                     configuration: configuration, script: .universal, forceScript: true, cancellation: cancellation)
                return reply(true, "The JIT helper finished and detached.")
#if DEBUG
            case .diagnosticWait: preconditionFailure("Handled above")
#endif
            case .resetDDI: preconditionFailure("Handled above")
            }
        } catch {
            // Framework errors may contain paths/identifiers; never return or log raw credential errors.
            return reply(false, "The JIT operation failed. Check pairing, LocalDevVPN and Developer Mode.")
        }
    }
}

@objc(MeloNXJITHelperHandler)
final class MeloNXJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let data = (context.inputItems.first as? NSExtensionItem)?.userInfo?[JITRequest.itemKey] as? Data
        guard let data, let request = try? JITRequest.decode(data) else {
            context.cancelRequest(withError: JITTransportError.invalidResponse)
            return
        }
        let cancellation = StikJITCancellation()
        let signal = JITCancellationSignal.name(for: request.operationID)
        JITHelperCancellations.register(cancellation, name: signal)
        MeloNXJITWork.queue.async {
            defer { JITHelperCancellations.remove(name: signal) }
            let reply = MeloNXJITWork.handle(request, cancellation: cancellation)
            guard let encoded = try? JSONEncoder().encode(reply), encoded.count <= 65_536 else {
                context.cancelRequest(withError: JITTransportError.invalidResponse)
                return
            }
            let item = NSExtensionItem()
            item.userInfo = [JITReply.itemKey: encoded]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}

// Out-of-band cancellation is never queued behind a synchronous worker. The
// callback resolves a strong token by nonce; it holds no borrowed C pointers.
private enum JITHelperCancellations {
    static let lock = NSLock()
    static var tokens: [String: StikJITCancellation] = [:]
    static func register(_ token: StikJITCancellation, name: String) {
        lock.lock(); tokens[name] = token; lock.unlock()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
            guard let name else { return }
            let key = name.rawValue as String
            JITHelperCancellations.lock.lock()
            let token = JITHelperCancellations.tokens[key]
            JITHelperCancellations.lock.unlock()
            token?.cancel()
        }, name as CFString, nil, .deliverImmediately)
    }
    static func remove(name: String) {
        lock.lock(); tokens.removeValue(forKey: name); lock.unlock()
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, CFNotificationName(name as CFString), nil)
    }
}
