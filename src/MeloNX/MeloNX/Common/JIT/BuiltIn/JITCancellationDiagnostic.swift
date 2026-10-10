#if DEBUG
import Foundation
import MeloNXJITCore

@MainActor enum JITAcquisitionDiagnostic {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--jit-acquisition-proof") }
    private static var started = false
    private static var history: [[String: Any]] = []
    static func record(phase: String, message: String, retry: Bool, port: UInt16) {
        let snapshot = JITDebuggerProbe.snapshot()
        history.append(["phase": phase, "message": message, "canRetry": retry,
                        "controllerJITEnabled": RyujinxController.shared.isJITEnabled,
                        "mappingReadyPublished": JITMappingWorker.shared.isReady,
                        "remotePairingPort": Int(port), "codeSigningDebugged": snapshot.codeSigningDebugged,
                        "currentlyTraced": snapshot.currentlyTraced.map { $0 ? "yes" : "no" } ?? "unknown"])
        history = Array(history.suffix(32))
        let value: [String: Any] = ["history": history, "passed": phase == "ready" && snapshot.currentlyTraced == false
            && RyujinxController.shared.isJITEnabled && JITMappingWorker.shared.isReady]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: documents.appendingPathComponent("jit-acquisition-proof.json"), options: .atomic)
    }
    static func run() async {
        guard !started else { return }
        started = true
        _ = await BuiltInJITCoordinator.shared.enable()
    }
}

/// Explicit local development import, using the same native installer as the UI.
/// Fixed sandbox paths; the proof contains no key material.
@MainActor enum FirmwareImportDiagnostic {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--import-firmware-22-5-0") }
    private static var started = false

    static func run() async {
        guard !started else { return }
        started = true
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let proof = documents.appendingPathComponent("firmware-import-proof.json")
        var evidence: [String: Any] = ["passed": false, "status": "started"]
        func save() {
            guard let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) else { return }
            try? data.write(to: proof, options: .atomic)
        }
        save()
        let controller = RyujinxController.shared
        let prodValid = controller.verifyKeysFile(path: .keysFolderURL, keys: .prod)
        let titleValid = controller.verifyKeysFile(path: .keysFolderURL, keys: .title)
        evidence["prodKeysValid"] = prodValid
        evidence["titleKeysValid"] = titleValid
        guard prodValid && titleValid else {
            evidence["status"] = "invalid-keys"; save(); return
        }
        Ryujinx.reloadKeySet()
        let path = documents.appendingPathComponent("Downloads/Firmware.22.5.0.zip").path
        let version = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try Ryujinx.installFirmware(at: path)
                return Ryujinx.installedFirmwareVersion
            } catch { return nil }
        }.value
        evidence["installedFirmwareVersion"] = version ?? ""
        evidence["passed"] = version == "22.5.0"
        evidence["status"] = version == "22.5.0" ? "installed" : "failed"
        save()
    }
}

/// Invoked explicitly through a development launch argument. No pairing credentials,
/// mapper or game are touched; results contain only worker/tracing proof facts.
@MainActor enum JITCancellationDiagnostic {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--jit-helper-cancel-proof") }
    static func run() async {
        var evidence: [String: Any] = ["proof": "isolated-worker", "passed": false]
        func save() {
            guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let bytes = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]) else { return }
            try? bytes.write(to: directory.appendingPathComponent("jit-cancellation-proof.json"), options: .atomic)
        }
        do {
            let session = try JITExtensionHost.shared.start(JITRequest(operationID: UUID(), operation: .diagnosticWait))
            let startupDeadline = Date().addingTimeInterval(15)
            while session.helperPID == nil && Date() < startupDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let pid = session.helperPID else {
                evidence["reason"] = "No helper PID arrived"; save(); return
            }
            evidence["helperPID"] = pid
            evidence["workerBeforeCancellation"] = session.workerHasEnded.map { $0 ? "ended" : "alive" } ?? "unknown"
            save()
            // Allow the helper to enter its deliberately blocked serial worker.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try session.requestCancellation()
            evidence["cancellationRequested"] = true
            save()
            let stopDeadline = Date().addingTimeInterval(15)
            while session.workerHasEnded != true && Date() < stopDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            evidence["workerEnded"] = session.workerHasEnded.map { $0 ? "ended" : "alive" } ?? "unknown"
            evidence["traced"] = JITExtensionHost.tracing.map { $0 ? "yes" : "no" } ?? "unknown"
            var joinedNormally = false
            if session.workerHasEnded == true {
                let reply = try await session.terminalResult()
                joinedNormally = reply.success
                evidence["ownedWorkerJoinAcknowledged"] = reply.success
            }
            evidence["passed"] = joinedNormally && session.workerHasEnded == true && JITExtensionHost.tracing == false
            save()
        } catch {
            evidence["reason"] = (error as? JITTransportError)?.localizedDescription ?? "Diagnostic setup or cancellation failed"
            save()
        }
    }
}
#endif
