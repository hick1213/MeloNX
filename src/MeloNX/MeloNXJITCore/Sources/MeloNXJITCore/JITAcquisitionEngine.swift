import Foundation

@MainActor private final class Outcome<Value> { var result: Result<Value, Error>? }
private struct OperationFailure: Error { let reason: String }

/// Production lifecycle. UI adapters publish this state; they do not run a
/// second acquisition algorithm. Cancellation invalidates the launch immediately
/// and retains the native operation lease until its actual completion.
@MainActor public final class JITAcquisitionEngine {
    public private(set) var state = JITSessionState()
    public private(set) var message = ""
    public var onChange: (() -> Void)?
    private let pairing: any JITPairingStoring
    private let network: any JITNetworkChecking
    private let helper: any JITHelperStarting
    private let mapping: any JITMapping
    private let debugger: @Sendable () -> JITDebuggerSnapshot
    private let clock: any JITClock
    private var session: (any JITHelperSession)?
    private var terminal: Outcome<JITReply>?
    private var mapped: Outcome<Bool>?
    private var processReady = false
    private var monitor: Task<Void, Never>?
    private let resolveEndpoint: @MainActor (Data) async -> UInt16
    public private(set) var endpointPort: UInt16 = 49152
    private var failureReason: String?

    public init(pairing: any JITPairingStoring, network: any JITNetworkChecking,
                helper: any JITHelperStarting, mapping: any JITMapping,
                debugger: @escaping @Sendable () -> JITDebuggerSnapshot, clock: any JITClock,
                resolveEndpoint: @escaping @MainActor (Data) async -> UInt16 = { _ in 49152 }) {
        self.pairing = pairing; self.network = network; self.helper = helper
        self.mapping = mapping; self.debugger = debugger; self.clock = clock
        self.resolveEndpoint = resolveEndpoint
    }
    private func changed() { onChange?() }
    private func phase(_ phase: JITPhase, id: UUID) { _ = state.transition(id: id, to: phase); changed() }
    private func start(_ request: JITRequest) throws -> Outcome<JITReply> {
        let session = try helper.start(request)
        self.session = session
        let box = Outcome<JITReply>(); terminal = box
        Task {
            do { box.result = .success(try await session.terminalResult()) }
            catch { box.result = .failure(error) }
        }
        return box
    }
    private func wait<Value>(_ box: Outcome<Value>, until deadline: TimeInterval, id: UUID) async -> Result<Value, Error>? {
        while box.result == nil && clock.now < deadline {
            if state.phase == .stopping { return nil }
            do { try await clock.sleep(for: 0.02) } catch { cancel(); return nil }
        }
        guard state.activeID == id else { return nil }
        return box.result
    }
    private func validatedRecord(id: UUID) throws -> PairingRecord {
        guard let record = try pairing.load() else {
            phase(.needsSetup, id: id)
            throw JITValidationError.missingPairing
        }
        return try PairingRecord(validating: record.data)
    }
    private func authenticate(_ record: PairingRecord, id: UUID) async throws {
        let route = await network.check()
        guard route.canAttemptAuthentication else { throw OperationFailure(reason: "LocalDevVPN is not reachable. Connect its tunnel before retrying.") }
        endpointPort = await resolveEndpoint(record.data)
        guard state.activeID == id, state.phase != .stopping else { throw JITTransportError.cancelled }
        phase(.preparing, id: id)
        let box = try start(JITRequest(operationID: UUID(), operation: .prepare, pairingData: record.data, rsdPort: endpointPort))
        guard let result = await wait(box, until: clock.now + 600, id: id) else {
            cancel(); throw JITTransportError.cancelled
        }
        let reply = try result.get()
        guard reply.success else { throw OperationFailure(reason: reply.message) }
        guard reply.txmPresent != nil else { throw JITTransportError.invalidResponse }
        guard session?.workerHasEnded == true, debugger().currentlyTraced == false else {
            cancel(); throw JITTransportError.interrupted
        }
        session = nil; terminal = nil
    }
    public func enable(launchID: UUID?) async -> Bool {
        guard state.canRetry else { return false }
        let id: UUID
        do { id = try state.begin(pid: ProcessInfo.processInfo.processIdentifier, launchID: launchID) }
        catch { return false }
        mapped = nil; terminal = nil; session = nil
        failureReason = nil; message = ""
        changed()
        let snapshot = debugger()
        if processReady, snapshot.codeSigningDebugged, snapshot.currentlyTraced == false {
            state.complete(id: id, mapped: true, helperEnded: true, tracing: false)
            changed(); return true
        }
        processReady = false
        do {
            guard snapshot.currentlyTraced == false else { throw JITTransportError.interrupted }
            let record = try validatedRecord(id: id)
            try await authenticate(record, id: id)
            guard state.phase != .stopping else { throw JITTransportError.cancelled }
            phase(.attaching, id: id)
            let result = try start(JITRequest(operationID: UUID(), operation: .enable,
                                    targetPID: ProcessInfo.processInfo.processIdentifier, pairingData: record.data, rsdPort: endpointPort))
            let attachDeadline = clock.now + 15
            while clock.now < attachDeadline && state.phase != .stopping {
                let current = debugger()
                if current.codeSigningDebugged && current.currentlyTraced == true { break }
                if result.result != nil { break }
                try await clock.sleep(for: 0.02)
            }
            let attached = debugger()
            if let terminalResult = result.result {
                let reply = try terminalResult.get()
                if !reply.success { throw OperationFailure(reason: reply.message) }
            }
            guard state.phase != .stopping, attached.codeSigningDebugged, attached.currentlyTraced == true else {
                cancel(); throw OperationFailure(reason: "The debugger did not attach to MeloNX within 15 seconds.")
            }
            phase(.mapping, id: id)
            let box = Outcome<Bool>(); mapped = box
            Task {
                do { box.result = .success(try await mapping.initialize()) }
                catch { box.result = .failure(error) }
            }
            guard let mappingResult = await wait(box, until: clock.now + 120, id: id) else {
                cancel(); throw JITTransportError.cancelled
            }
            let didMap = try mappingResult.get()
            guard let helperResult = await wait(result, until: clock.now + 15, id: id) else {
                cancel(); throw JITTransportError.cancelled
            }
            let reply = try helperResult.get()
            guard reply.success else { throw OperationFailure(reason: reply.message) }
            let ready = didMap
            guard finish(id: id, ready: ready) else { cancel(); throw JITTransportError.interrupted }
            processReady = ready && state.phase == .ready
            message = processReady ? "JIT ready for this process." : "Native mapping failed."
            changed()
            return processReady
        } catch {
            failureReason = Self.safeReason(error)
            message = failureReason! + " Waiting for confirmed teardown before retry."
            if state.phase == .stopping {
                await stopAndObserve(id: id)
            } else if !finish(id: id, ready: false) {
                cancel(); await stopAndObserve(id: id)
            }
            changed(); return false
        }
    }
    public func cancel() {
        guard let id = state.activeID else { return }
        state.cancel(id: id)
        do { try session?.requestCancellation() }
        catch { message = JITTransportError.cancellationUnavailable.localizedDescription }
        changed()
    }
    private func finish(id: UUID, ready: Bool, preparedOnly: Bool = false) -> Bool {
        guard state.activeID == id else { return false }
        let mappingEnded = mapped == nil || mapped?.result != nil
        let helperEnded = session == nil || (terminal?.result != nil && session?.workerHasEnded == true)
        guard mappingEnded, helperEnded, debugger().currentlyTraced == false else { return false }
        state.complete(id: id, mapped: ready, helperEnded: true, tracing: false, preparedOnly: preparedOnly)
        if let failureReason, !ready { message = failureReason + " Cleanup confirmed. You can retry." }
        session = nil; terminal = nil; mapped = nil
        changed(); return true
    }
    private func stopAndObserve(id: UUID) async {
        let deadline = clock.now + 15
        while state.activeID == id && clock.now < deadline {
            if finish(id: id, ready: false) { return }
            do { try await clock.sleep(for: 0.02) } catch { break }
        }
        guard state.activeID == id else { return }
        message = (failureReason.map { $0 + " " } ?? "") + "Teardown is unverified. Retry remains disabled while the worker or debugger is active."
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state.activeID == id else { return }
                if self.finish(id: id, ready: false) { return }
                do { try await self.clock.sleep(for: 0.1) } catch { return }
            }
        }
    }
    public func prepare() async { await simple(.prepare) }
    public func resetDDI() async { await simple(.resetDDI) }
    private func simple(_ operation: JITOperation) async {
        guard state.canRetry else { return }
        let id: UUID
        do { id = try state.begin(pid: ProcessInfo.processInfo.processIdentifier, launchID: nil) }
        catch { return }
        mapped = nil; terminal = nil; session = nil
        failureReason = nil; message = ""
        do {
            if operation == .prepare {
                let record = try validatedRecord(id: id)
                try await authenticate(record, id: id)
                message = "Device authenticated and DDI prepared. JIT mapping has not started."
            } else {
                let result = try start(JITRequest(operationID: UUID(), operation: .resetDDI))
                guard let reply = await wait(result, until: clock.now + 30, id: id), try reply.get().success else {
                    cancel(); throw JITTransportError.interrupted
                }
                message = "DDI cache reset."
            }
            if !finish(id: id, ready: false, preparedOnly: true) { cancel(); await stopAndObserve(id: id) }
        } catch {
            failureReason = Self.safeReason(error)
            message = failureReason!
            if !finish(id: id, ready: false) { cancel(); await stopAndObserve(id: id) }
        }
        changed()
    }
    private static func safeReason(_ error: Error) -> String {
        if let error = error as? OperationFailure { return error.reason }
        if let error = error as? JITValidationError { return error.localizedDescription }
        if let error = error as? JITTransportError { return error.localizedDescription }
        return "The native JIT operation failed."
    }
}
