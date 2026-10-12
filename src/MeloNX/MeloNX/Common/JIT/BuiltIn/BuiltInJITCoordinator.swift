import Foundation
import Combine
import MeloNXJITCore
import MeloNXOperationCore

@MainActor final class BuiltInJITCoordinator: ObservableObject {
    static let shared = BuiltInJITCoordinator()
    @Published private(set) var phase: JITPhase = .idle
    @Published private(set) var message = ""
    @Published private(set) var elapsed: TimeInterval = 0
    private let clock = SystemJITClock()
    private let engine: JITAcquisitionEngine
    private var ticker: Task<Void, Never>?
    private var operation: LocalOperationLease?
    private var borrowedWorker: LocalWorkerLease?
    private var externalActive = false
    private let automatic = JITAutomaticRequest()
    private var automaticCancelled = false
    var automaticAcquisitionActive: Bool { automatic.isRunning }
    func waitForAutomaticAcquisition() async { _ = await automatic.waitForCurrent() }
    var canRetry: Bool { engine.state.canRetry && !externalActive && !JITDevicePairing.shared.active }
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
        finishOperationIfEnded()
        phase = engine.state.phase; message = engine.message
#if DEBUG
        if JITAcquisitionDiagnostic.requested {
            JITAcquisitionDiagnostic.record(phase: phase.rawValue, message: message,
                retry: engine.state.canRetry, port: engine.endpointPort)
        }
#endif
    }
    private func beginOperation(launchID: UUID? = nil) -> Bool {
        guard operation == nil, borrowedWorker == nil else { return false }
        do {
            if let pending = RyujinxController.shared.pendingGameLease(launchID: launchID) {
                borrowedWorker = try pending.retainWorker()
            } else {
                guard launchID == nil else { return false }
                operation = try LocalOperations.shared.acquire(.launch, gameID: nil)
            }
            return true
        } catch { message = error.localizedDescription; return false }
    }
    private func finishOperationIfEnded() {
        guard engine.state.canRetry, !externalActive else { return }
        if let worker = borrowedWorker { try? worker.finish(); borrowedWorker = nil }
        if let lease = operation { try? lease.finish(workerHasEnded: true); operation = nil }
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
        guard beginOperation(launchID: launchID) else { return false }
        beginTicker(); defer { ticker?.cancel(); publish() }
        let ready = await engine.enable(launchID: launchID)
        if ready { publishReadiness() }
        return ready
    }
    func enableAutomatically() async -> Bool {
        if RyujinxController.shared.isJITEnabled { return true }
        guard !automaticCancelled else { return false }
        return await automatic.run { [self] in
            defer { recordAutomaticReadiness() }
            guard await SaveRecoveryBootstrap.shared.ensureReady(),
                  !automaticCancelled,
                  RyujinxController.shared.pendingLaunchID == nil,
                  !RyujinxController.shared.isRunning.hasStarted(), canRetry else { return false }
            let provider = NativeSettingsManager.shared.jitProvider(JITProvider.disabled).value
            let preference = UserDefaults.standard.object(forKey: "preferBuiltInJIT") as? Bool
            let builtIn = JITCompatibilityPolicy.useBuiltIn(preference: preference, externalProviderSelected: provider != .disabled)
            let ready: Bool
            if builtIn, unavailableReason == nil {
                guard (try? JITKeychainPairingStore.shared.load()) != nil else {
                    message = "请先完成内置 JIT 配对并连接 LocalDevVPN。"
                    return false
                }
                ready = await enable()
            } else {
                if !checkDebugged() { EnableJIT.enableJIT(provider) }
                ready = await enableExternal()
            }
            print("[JIT] Automatic acquisition ready=\(ready)")
            return ready
        }
    }
    private func recordAutomaticReadiness() {
        let evidence: [String: Any] = ["ready": RyujinxController.shared.isJITEnabled,
            "phase": phase.rawValue, "pid": ProcessInfo.processInfo.processIdentifier,
            "uptime": ProcessInfo.processInfo.systemUptime]
        let directory = URL.logsFolderURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("jit-auto-status.json"), options: .atomic)
        }
    }
    func prepare() async {
        guard canRetry, unavailableReason == nil else { message = unavailableReason ?? "Wait for the previous operation."; return }
        guard beginOperation() else { return }
        beginTicker(); defer { ticker?.cancel(); publish() }
        await engine.prepare()
    }
    func resetDDI() async {
        guard canRetry else { return }
        guard beginOperation() else { return }
        beginTicker(); defer { ticker?.cancel(); publish() }
        await engine.resetDDI()
    }
    func enableExternal(launchID: UUID? = nil) async -> Bool {
        guard canRetry, checkDebugged() else { return false }
        guard beginOperation(launchID: launchID) else { return false }
        externalActive = true
        defer { externalActive = false; finishOperationIfEnded() }
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
    func cancel() {
        automaticCancelled = true
        RyujinxController.shared.cancelAutomaticLaunch()
        engine.cancel(); publish()
    }
}
