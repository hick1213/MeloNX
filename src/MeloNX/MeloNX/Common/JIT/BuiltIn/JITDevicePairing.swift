// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Madeira; see distribution/legal/Madeira-JIT-EXCEPTION.md

import BackgroundTasks
import Combine
import dnssd
import Foundation
import SwiftUI
import UIKit
import MeloNXJITCore

// On-device pairing for Built-in StikJIT (docs/JIT.md, "On-device pairing").
//
// iOS 27 can pair with a computer it finds on the local network, started from
// the iPhone: Settings › Privacy & Security › Developer Mode lists every
// `_remotepairing-pairable-host._tcp` service, and pairing with one asks for the
// PIN that host shows. MeloNX plays that computer for its own iPhone:
// libmelonx_rppairing (build/rppairing-ios, idevice's PairableHost) listens on
// a port and runs the pairing; this file publishes the port through
// mDNSResponder (dns_sd, so only the Local Network permission is needed, not
// the multicast entitlement) and stores the resulting RPPairing file where
// Built-in StikJIT reads it.
//
// The user pairs from Settings, so MeloNX has to keep running in the
// background: a BGContinuedProcessingTask ("<bundle id>.pairing.session",
// permitted by `$(PRODUCT_BUNDLE_IDENTIFIER).pairing.*` in Info.plist) whose
// system progress UI also shows the PIN. When iOS refuses it (for example a
// re-signed bundle whose identifier no longer matches), only the short
// background grace period remains, and the page says so. The PIN is also sent
// in the continued-processing progress UI.
//
// Log tag: [jit-pairing] (states only: no PIN, device name or identifiers).
@MainActor final class JITDevicePairing: ObservableObject {
    static let shared = JITDevicePairing()

    /// Shown on the iPhone as "Pair with MeloNX"; the host identifier is derived from it.
    static let hostName = "MeloNX"
    static let timeout: TimeInterval = 300

    enum Phase: Equatable {
        case idle
        /// Advertised; the user pairs from Settings.
        case stopping
        case waiting
        /// The iPhone asked for the code.
        case pin(String)
        case paired(device: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// iOS refused the continued-processing task: MeloNX can only wait briefly in the background.
    @Published private(set) var backgroundLimited = false

    static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    var isShowingPin: Bool {
        if case .pin = phase { return true }
        return false
    }

    var active: Bool { session != nil }

    private var session: OpaquePointer?
    private var registration: DNSServiceRef?
    private var continued: AnyObject?            // BGContinuedProcessingTask (iOS 26+)
    private var advertisementContext: Unmanaged<PairingPINContext>?
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var deadline: Timer?

    private var attempt = PairingAttemptState()
    private var pending: CheckedContinuation<PairingRecord, Error>?
    private var stopReason: String?

    private init() {}

    private func log(_ line: String) { print("[jit-pairing] " + line) }

    func start() async throws -> PairingRecord {
        guard Self.isSupported else { throw Self.error("On-device pairing requires iPadOS 27 or later.") }
        guard !active, pending == nil else { throw JITValidationError.busy }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.pending = continuation
                self.beginPairing()
            }
        }, onCancel: { Task { @MainActor in self.cancel() } })
    }

    private func beginPairing() {
        let id: UUID
        do { id = try attempt.begin() }
        catch { finishPending(.failure(error)); return }
        stopReason = nil
        var error: UnsafeMutablePointer<CChar>?
        guard let session = melonx_rppairing_new(Self.hostName, &error) else {
            _ = attempt.finish(id: id)
            fail(Self.take(error) ?? "MeloNX could not open its pairing port.")
            return
        }
        self.session = session
        phase = .waiting
        backgroundLimited = false
        log("started")
        guard publish(session, id: id) else {
            melonx_rppairing_free(session)
            self.session = nil
            _ = attempt.finish(id: id)
            finishPending(.failure(Self.error("MeloNX could not advertise its pairing service. Allow Local Network access and try again.")))
            return
        }
        beginBackground(id: id)
        deadline = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard JITDevicePairing.shared.attempt.ownsCallback(id: id) else { return }
                JITDevicePairing.shared.cancel(reason: "Pairing timed out. Try again when you are ready to pair from Settings.") }
        }

        let pinContext = Unmanaged.passRetained(PairingPINContext(id: id))
        DispatchQueue.global(qos: .userInitiated).async {
            defer { pinContext.release() }
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            var device: UnsafeMutablePointer<CChar>?
            var failure: UnsafeMutablePointer<CChar>?
            let status = melonx_rppairing_accept(session, { pin, context in
                guard let pin, let context else { return }
                let id = Unmanaged<PairingPINContext>.fromOpaque(context).takeUnretainedValue().id
                let code = String(cString: pin)
                DispatchQueue.main.async { JITDevicePairing.shared.showPin(code, id: id) }
            }, pinContext.toOpaque(), &bytes, &length, &device, &failure)
            let data = bytes.flatMap { length > 0 && length <= 1_048_576 ? Data(bytes: $0, count: length) : nil }
            melonx_rppairing_bytes_free(bytes, length)
            let name = Self.take(device)
            let message = Self.take(failure)
            DispatchQueue.main.async {
                JITDevicePairing.shared.finished(id: id, status: status, data: data, device: name, message: message)
            }
        }
    }

    /// Stops a pairing in progress. `reason` is shown as the failure; nil returns to idle.
    func cancel(reason: String? = nil) {
        guard let session else { return }
        melonx_rppairing_cancel(session)
        stopAdvertising()
        if let id = attempt.activeID { attempt.cancel(id: id) }
        stopReason = reason
        phase = .stopping
        log(reason == nil ? "cancelled" : "stopped")
    }

    private func showPin(_ pin: String, id: UUID) {
        guard active, attempt.activeID == id, !attempt.isCancelled else { return }
        phase = .pin(pin)
        log("code shown")
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.updateTitle("Pairing code \(pin)", subtitle: "Enter it on this \(Self.deviceKind) to pair with MeloNX")
            task.progress.completedUnitCount = 1
        }

    }

    private func finished(id: UUID, status: Int32, data: Data?, device: String?, message: String?) {
        guard attempt.activeID == id else { return }
        if let session { melonx_rppairing_free(session) }
        session = nil
        stopAdvertising()
        deadline?.invalidate()
        deadline = nil
        let mayStore = attempt.finish(id: id)
        guard mayStore, status != 2 else {
            phase = stopReason.map(Phase.failed) ?? .idle
            endBackground(success: false)
            finishPending(.failure(stopReason.map(Self.error) ?? CancellationError()))
            return
        }
        guard status == 0, let data else {
            fail(message.map { "Pairing failed: \($0.prefix(2048))" } ?? "Pairing failed. Try again.")
            return
        }
        do {
            let record = try PairingRecord(validating: data)
            try JITKeychainPairingStore.shared.replace(with: record.data)
            phase = .paired(device: device ?? "this \(Self.deviceKind)")
            log("paired")
            endBackground(success: true)
            finishPending(.success(record))
        } catch { fail("Pairing finished, but MeloNX could not save the pairing credential. Unlock this device and retry.") }
    }

    private func fail(_ message: String) {
        if let session {
            melonx_rppairing_cancel(session)
            if let id = attempt.activeID { attempt.cancel(id: id) }
            stopReason = message
            phase = .stopping
        } else {
            phase = .failed(message)
            finishPending(.failure(Self.error(message)))
        }
        stopAdvertising()
        log("failed")
        endBackground(success: false)
    }

    private func finishPending(_ result: Result<PairingRecord, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "MeloNXJITPairing", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static var deviceKind: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    nonisolated private static func take(_ string: UnsafeMutablePointer<CChar>?) -> String? {
        guard let string else { return nil }
        defer { melonx_rppairing_string_free(string) }
        return String(cString: string)
    }

    // MARK: Advertising

    private func publish(_ session: OpaquePointer, id: UUID) -> Bool {
        let context = Unmanaged.passRetained(PairingPINContext(id: id))
        advertisementContext = context
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        for index in 0..<melonx_rppairing_txt_count(session) {
            guard let key = melonx_rppairing_txt_key(session, index),
                  let value = melonx_rppairing_txt_value(session, index) else { continue }
            TXTRecordSetValue(&txt, key, UInt8(clamping: strlen(value)), value)
        }
        var ref: DNSServiceRef?
        let error = DNSServiceRegister(
            &ref, 0, 0, melonx_rppairing_service_name(session), "_remotepairing-pairable-host._tcp", nil, nil,
            melonx_rppairing_port(session).bigEndian, TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
            { _, _, error, _, _, _, context in
                guard error != DNSServiceErrorType(kDNSServiceErr_NoError) else { return }
                guard let context else { return }
                let id = Unmanaged<PairingPINContext>.fromOpaque(context).takeUnretainedValue().id
                DispatchQueue.main.async { JITDevicePairing.shared.advertisingFailed(error, id: id) }
            }, context.toOpaque())
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            advertisingFailed(error, id: id)
            return false
        }
        DNSServiceSetDispatchQueue(ref, .main)
        registration = ref
        return true
    }

    private func advertisingFailed(_ error: DNSServiceErrorType, id: UUID) {
        guard active, attempt.ownsCallback(id: id) else { return }
        log("advertising failed error=\(error)")
        fail(error == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
             ? "MeloNX needs Local Network access to pair. Allow it in Settings › Apps › MeloNX, then try again."
             : "MeloNX could not announce itself on the local network. Check that Wi-Fi is on, then try again.")
    }

    private func stopAdvertising() {
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
        advertisementContext?.release()
        advertisementContext = nil
    }

    // MARK: Background

    /// The permitted "<bundle id>.pairing.*" identifier from Info.plist, made concrete.
    private var taskIdentifier: String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let wildcard = permitted.first(where: { $0.hasSuffix(".pairing.*") }) else { return nil }
        guard let id = attempt.activeID else { return nil }
        return String(wildcard.dropLast()) + id.uuidString
    }

    private func beginBackground(id: UUID) {
        grace = UIApplication.shared.beginBackgroundTask(withName: "MeloNX pairing") {
            MainActor.assumeIsolated {
                let pairing = JITDevicePairing.shared
                guard pairing.attempt.ownsCallback(id: id) else { return }
                if pairing.continued == nil && pairing.active {
                    pairing.cancel(reason: "iOS stopped MeloNX in the background before pairing finished. Try again, and pair from Settings straight away.")
                }
                pairing.endGrace()
            }
        }
        if #available(iOS 26.0, *) { submitContinued(id: id) } else { backgroundLimited = true }
    }

    @available(iOS 26.0, *)
    private func submitContinued(id: UUID) {
        guard let identifier = taskIdentifier else { backgroundLimited = true; return }
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { JITDevicePairing.shared.attach(task, id: id) }
        }
        guard ok else { log("register refused"); backgroundLimited = true; return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Pairing with MeloNX",
                                                       subtitle: "Settings › Privacy & Security › Developer Mode")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            log("continued-processing submitted")
        } catch {
            log("continued-processing refused")
            backgroundLimited = true
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask, id: UUID) {
        guard active, attempt.ownsCallback(id: id), !attempt.isCancelled else { task.setTaskCompleted(success: false); return }
        continued = task
        task.progress.totalUnitCount = 2
        if case .pin(let pin) = phase {
            task.updateTitle("Pairing code \(pin)", subtitle: "Enter it on this \(Self.deviceKind) to pair with MeloNX")
            task.progress.completedUnitCount = 1
        }
        task.expirationHandler = { [weak task] in
            DispatchQueue.main.async {
                guard let task else { return }
                let pairing = JITDevicePairing.shared
                guard pairing.attempt.ownsCallback(id: id), pairing.continued === task else { return }
                task.expirationHandler = nil
                task.setTaskCompleted(success: false)
                pairing.continued = nil
                pairing.cancel(reason: "iOS stopped the pairing in the background. Try again.")
            }
        }
        log("continued-processing running")
    }

    private func endBackground(success: Bool) {
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.expirationHandler = nil
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        continued = nil
        endGrace()
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

}

nonisolated private final class PairingPINContext: Sendable {
    let id: UUID
    init(id: UUID) { self.id = id }
}
