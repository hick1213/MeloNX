// SPDX-License-Identifier: MPL-2.0
// MeloNX replacement of StikJIT1.9.0 JITSession: no shared non-thread-safe FFI handles.
import Foundation

final class JITSession {
    private let pairingFilePath: String
    private let configuration: StikJIT.Configuration
    init(pairingFilePath: String, configuration: StikJIT.Configuration) {
        self.pairingFilePath = pairingFilePath
        self.configuration = configuration
    }
    func enableJIT(targetPID: Int32, script: StikJIT.Script, forceScript: Bool,
                   txmPresence: TXMPresence, cancellation: StikJITCancellation,
                   progress: @escaping (String) -> Void) throws {
        guard !cancellation.isCancelled else { throw OwnedDebugError.cancelled }
        let transport = try OwnedDebugTransport(pairingFile: URL(fileURLWithPath: pairingFilePath),
                                              configuration: configuration, cancellation: cancellation)
        do {
            switch (forceScript, txmPresence) {
            case (true, _), (false, .present):
                try ScriptRunner(targetPID: targetPID, transport: transport, script: script, progress: progress).run()
            case (false, .absent):
                _ = try transport.send("vAttach;\(String(targetPID, radix: 16))")
                guard try transport.send("D") == "OK" else { throw OwnedDebugError.transport }
            case (false, .unknown): throw StikJITError.txmDetectionUnavailable
            }
        } catch {
            try transport.closeAndWait()
            throw error
        }
        try transport.closeAndWait()
    }
}
