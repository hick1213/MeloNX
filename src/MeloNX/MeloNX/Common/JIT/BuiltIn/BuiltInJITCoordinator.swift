import Foundation
import Combine
import MeloNXJITCore

@MainActor final class BuiltInJITCoordinator: ObservableObject {
    static let shared = BuiltInJITCoordinator()
    @Published private(set) var phase: JITPhase = .idle
    @Published private(set) var message = ""
    @Published private(set) var elapsed: TimeInterval = 0
    private let clock = SystemJITClock()
    private let engine: JITAcquisitionEngine
    private var ticker: Task<Void, Never>?
    var canRetry: Bool { engine.state.canRetry && !JITDevicePairing.shared.active }
    var unavailableReason: String? {
        if let reason = JITExtensionHost.unavailableReason { return reason }
        guard checkAppEntitlement("get-task-allow") else { return "Built-in JIT needs development signing with get-task-allow." }
        guard JITHelperLocation.identifier(in: Bundle.main.builtInPlugInsURL) != nil else { return JITTransportError.missingHelper.localizedDescription }
        return nil
    }
    private init() {
        engine = JITAcquisitionEngine(pairing: JITKeychainPairingStore.shared, network: JITNetworkProbe(),
            helper: JITExtensionHost.shared, mapping: JITMappingWorker.shared,
            debugger: { JITDebuggerProbe.snapshot() }, clock: SystemJITClock(),
            resolveEndpoint: { await JITRemoteEndpoint.resolve(pairingData: $0) })
        engine.onChange = { [weak self] in self?.publish() }
    }
    private func publish() {
        phase = engine.state.phase; message = engine.message
#if DEBUG
        if JITAcquisitionDiagnostic.requested {
            JITAcquisitionDiagnostic.record(phase: phase.rawValue, message: message,
                retry: engine.state.canRetry, port: engine.endpointPort)
        }
#endif
    }
    private func beginTicker() {
        let start = clock.now; elapsed = 0
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsed = self.clock.now - start
                do { try await self.clock.sleep(for: 0.1) } catch { return }
            }
        }
    }
    func enable(launchID: UUID? = nil) async -> Bool {
        guard canRetry, unavailableReason == nil else { message = unavailableReason ?? "Wait for the previous operation."; return false }
        beginTicker(); defer { ticker?.cancel(); publish() }
        let ready = await engine.enable(launchID: launchID)
        if ready { publishReadiness() }
        return ready
    }
    func prepare() async {
        guard canRetry, unavailableReason == nil else { message = unavailableReason ?? "Wait for the previous operation."; return }
        beginTicker(); defer { ticker?.cancel(); publish() }
        await engine.prepare()
    }
    func resetDDI() async {
        guard canRetry else { return }
        beginTicker(); defer { ticker?.cancel(); publish() }
        await engine.resetDDI()
    }
    func enableExternal() async -> Bool {
        guard canRetry, checkDebugged() else { return false }
        let legacy = JITCompatibilityPolicy.useLegacyMapping(dynamicCodeSigning: checkAppEntitlement("dynamic-codesigning"),
            appOnMac: ProcessInfo.processInfo.isiOSAppOnMac, majorOS: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        let ready = await JITMappingWorker.shared.initializeExternal(legacy: legacy)
        guard ready, JITDebuggerProbe.snapshot().currentlyTraced == false else { return false }
        publishReadiness()
        return true
    }
    private func publishReadiness() {
        // Settings and game launch read a computed controller property. Notify
        // their observable owner when the process-local mapping becomes ready.
        RyujinxController.shared.objectWillChange.send()
        JITMappingWorker.shared.publishReady(true)
    }
    func cancel(launchID: UUID) {
        guard engine.state.pendingLaunchID == launchID else { return }
        cancel()
    }
    func cancel() { engine.cancel(); publish() }
}
