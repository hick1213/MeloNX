import XCTest
@testable import MeloNXJITCore

@MainActor final class JITCoordinatorTests: XCTestCase {
    func testCompletedFailureReportsReasonInsteadOfWaitingForTeardown() async throws {
        let fixture = try Fixture()
        fixture.helper.preparationSuccess = false
        let result = await fixture.engine.enable(launchID: nil)
        XCTAssertFalse(result)
        XCTAssertTrue(fixture.engine.state.canRetry)
        XCTAssertTrue(fixture.engine.message.contains("finished"))
        XCTAssertFalse(fixture.engine.message.contains("Waiting for confirmed teardown"))
    }
    func testResolvedPortIsSharedByPreparationAndAttach() async throws {
        let fixture = try Fixture(endpointPort: 56958)
        let work = Task { await fixture.engine.enable(launchID: nil) }
        await fixture.mapping.waitForStart()
        XCTAssertEqual(fixture.helper.requests.map(\.rsdPort), [56958, 56958])
        await fixture.mapping.release(true)
        fixture.helper.finish()
        let ready = await work.value
        XCTAssertTrue(ready)
    }
    func testCancellationDuringEndpointLookupCannotStartHelper() async throws {
        let endpoint = HeldEndpoint()
        let fixture = try Fixture(endpoint: endpoint)
        let work = Task { await fixture.engine.enable(launchID: nil) }
        while !endpoint.started { await Task.yield() }
        fixture.engine.cancel()
        XCTAssertFalse(fixture.engine.state.canRetry)
        endpoint.release()
        let ready = await work.value
        XCTAssertFalse(ready)
        XCTAssertTrue(fixture.engine.state.canRetry)
        XCTAssertTrue(fixture.helper.requests.isEmpty)
    }
    func testPortCodecRejectsZeroAndNonConnectionOperations() throws {
        let record = try pairingFixture()
        let request = JITRequest(operationID: UUID(), operation: .prepare, pairingData: record, rsdPort: 56958)
        XCTAssertEqual(try JITRequest.decode(JSONEncoder().encode(request)).rsdPort, 56958)
        XCTAssertThrowsError(try JITRequest(operationID: UUID(), operation: .prepare, pairingData: record, rsdPort: 0).validated())
        XCTAssertThrowsError(try JITRequest(operationID: UUID(), operation: .resetDDI, rsdPort: 56958).validated())
    }
    func testCancelledHeldMapperCannotLaunchOrStartAnotherHelper() async throws {
        let fixture = try Fixture()
        let launch = UUID()
        let work = Task { await fixture.engine.enable(launchID: launch) }
        await fixture.mapping.waitForStart()
        let responsive = await Task { @MainActor in true }.value
        XCTAssertTrue(responsive)
        fixture.engine.cancel()
        XCTAssertEqual(fixture.engine.state.phase, .stopping)
        XCTAssertNil(fixture.engine.state.allowedLaunchID)
        XCTAssertFalse(fixture.engine.state.canRetry)
        let duplicate = await fixture.engine.enable(launchID: UUID())
        XCTAssertFalse(duplicate)
        XCTAssertEqual(fixture.helper.enables, 1)
        await fixture.mapping.release(true)
        fixture.helper.finish()
        let result = await work.value
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.engine.state.phase, .cancelled)
    }
    func testReadyRequiresMappedAndUntracedTerminalAndCanReuseProcess() async throws {
        let fixture = try Fixture()
        let launch = UUID()
        let work = Task { await fixture.engine.enable(launchID: launch) }
        await fixture.mapping.waitForStart()
        XCTAssertNil(fixture.engine.state.allowedLaunchID)
        await fixture.mapping.release(true)
        fixture.helper.finish()
        let result = await work.value
        XCTAssertTrue(result)
        XCTAssertEqual(fixture.engine.state.allowedLaunchID, launch)
        let next = UUID()
        let again = await fixture.engine.enable(launchID: next)
        XCTAssertTrue(again)
        XCTAssertEqual(fixture.helper.enables, 1)
        XCTAssertEqual(fixture.engine.state.allowedLaunchID, next)
    }
    func testUnknownTracingCannotStartMapperOrClaimReady() async throws {
        let fixture = try Fixture()
        fixture.helper.attach = nil
        fixture.clock.step = 50
        let result = await fixture.engine.enable(launchID: UUID())
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.mapping.starts, 0)
        XCTAssertNil(fixture.engine.state.allowedLaunchID)
        XCTAssertFalse(fixture.engine.state.canRetry)
        fixture.helper.finish()
    }
    func testPersistentDebuggedFlagIsNotCurrentAttach() async throws {
        let fixture = try Fixture()
        fixture.helper.attach = false
        fixture.clock.step = 50
        let result = await fixture.engine.enable(launchID: UUID())
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.mapping.starts, 0)
        XCTAssertFalse(fixture.engine.state.canRetry)
        fixture.helper.finish()
    }
    func testInvalidPairingAndUnavailableRouteStartNoHelper() async throws {
        let fixture = try Fixture()
        fixture.pairing.data = Data("bad".utf8)
        let result = await fixture.engine.enable(launchID: UUID())
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.helper.enables, 0)
        XCTAssertTrue(fixture.engine.state.canRetry)
        let noRoute = try Fixture(network: false)
        let routeResult = await noRoute.engine.enable(launchID: UUID())
        XCTAssertFalse(routeResult)
        XCTAssertEqual(noRoute.helper.enables, 0)
    }
    func testPrepareDoesNotClaimMappedReadiness() async throws {
        let fixture = try Fixture()
        await fixture.engine.prepare()
        XCTAssertEqual(fixture.engine.state.phase, .idle)
        XCTAssertNil(fixture.engine.state.allowedLaunchID)
        XCTAssertEqual(fixture.mapping.starts, 0)
    }
    func testMissingCredentialKeepsSetupState() async throws {
        let fixture = try Fixture()
        fixture.pairing.data = nil
        let result = await fixture.engine.enable(launchID: UUID())
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.engine.state.phase, .needsSetup)
        XCTAssertTrue(fixture.engine.state.canRetry)
    }
    func testFailedPreparationOrUnknownTXMDoesNotAttach() async throws {
        for unknown in [false, true] {
            let fixture = try Fixture()
            fixture.helper.preparationSuccess = unknown
            fixture.helper.txm = unknown ? nil : true
            let result = await fixture.engine.enable(launchID: UUID())
            XCTAssertFalse(result)
            XCTAssertEqual(fixture.helper.enables, 0)
            XCTAssertNil(fixture.engine.state.allowedLaunchID)
        }
    }
    func testInitialPreparationCanContinuePastThreeMinutes() async throws {
        let fixture = try Fixture()
        fixture.clock.step = 0
        fixture.helper.delayedPreparation = true
        let work = Task { await fixture.engine.prepare() }
        while fixture.helper.preparing == nil { await Task.yield() }
        fixture.clock.advance(to: 181)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.engine.state.phase, .preparing)
        fixture.helper.preparing?.finish(true)
        await work.value
        XCTAssertEqual(fixture.engine.state.phase, .idle)
    }
    func testMapperFailureNeverStartsGame() async throws {
        let fixture = try Fixture()
        let work = Task { await fixture.engine.enable(launchID: UUID()) }
        await fixture.mapping.waitForStart()
        await fixture.mapping.release(false)
        fixture.helper.finish()
        let result = await work.value
        XCTAssertFalse(result)
        XCTAssertNil(fixture.engine.state.allowedLaunchID)
    }
}

@MainActor private final class Fixture {
    let pairing = FakePairing()
    let probe = ProbeBox()
    let helper: FakeHelper
    let mapping = HeldMapping()
    let clock = FakeClock()
    let engine: JITAcquisitionEngine
    init(network: Bool = true, endpointPort: UInt16 = 49152, endpoint: HeldEndpoint? = nil) throws {
        pairing.data = try pairingFixture()
        helper = FakeHelper(probe: probe)
        let probe = probe
        engine = JITAcquisitionEngine(pairing: pairing, network: FakeNetwork(reachable: network),
             helper: helper, mapping: mapping, debugger: { probe.snapshot }, clock: clock,
             resolveEndpoint: { _ in await endpoint?.resolve() ?? endpointPort })
    }
}
@MainActor private final class HeldEndpoint {
    var started = false
    private var continuation: CheckedContinuation<UInt16, Never>?
    func resolve() async -> UInt16 {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: 56958); continuation = nil }
}
@MainActor private final class FakePairing: JITPairingStoring {
    var data: Data?
    func load() throws -> PairingRecord? { try data.map { try PairingRecord(validating: $0) } }
    func replace(with data: Data) throws { self.data = try PairingRecord(validating: data).data }
}
private struct FakeNetwork: JITNetworkChecking {
    let reachable: Bool
    func check() async -> JITNetworkStatus { .init(canAttemptAuthentication: reachable, reason: "route unavailable") }
}
private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var traced: Bool? = false
    var snapshot: JITDebuggerSnapshot { lock.lock(); defer { lock.unlock() }; return .init(codeSigningDebugged: true, currentlyTraced: traced) }
    func set(_ value: Bool?) { lock.lock(); traced = value; lock.unlock() }
}
private final class FakeClock: @unchecked Sendable, JITClock {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    var step: TimeInterval = 0.01
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func sleep(for seconds: TimeInterval) async throws {
        await Task.yield()
        tick()
    }
    func advance(to value: TimeInterval) { lock.lock(); time = value; lock.unlock() }
    private func tick() { lock.lock(); time += step; lock.unlock() }
}
private actor HeldMapping: JITMapping {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    nonisolated(unsafe) private(set) var starts = 0
    func initialize() async throws -> Bool {
        starts += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedWaiter?.resume(); startedWaiter = nil
        }
    }
    func waitForStart() async { if starts > 0 { return }; await withCheckedContinuation { startedWaiter = $0 } }
    func release(_ value: Bool) { continuation?.resume(returning: value); continuation = nil }
}
@MainActor private final class FakeHelper: JITHelperStarting {
    let probe: ProbeBox
    var attach: Bool? = true
    var enables = 0
    var preparationSuccess = true
    var delayedPreparation = false
    var preparing: FakeSession?
    var txm: Bool? = true
    var active: FakeSession?
    var requests: [JITRequest] = []
    init(probe: ProbeBox) { self.probe = probe }
    func start(_ request: JITRequest) throws -> any JITHelperSession {
        requests.append(request)
        let session = FakeSession(id: request.operationID)
        if request.operation == .enable { enables += 1; active = session; probe.set(attach) }
        else if delayedPreparation { preparing = session }
        else { session.finish(preparationSuccess, txm: txm) }
        return session
    }
    func finish() { probe.set(false); active?.finish(true) }
}
@MainActor private final class FakeSession: JITHelperSession {
    let operationID: UUID
    var helperPID: Int32? = 200
    var workerHasEnded: Bool? = false
    private var result: JITReply?
    private var waiter: CheckedContinuation<JITReply, Error>?
    init(id: UUID) { operationID = id }
    func requestCancellation() throws {} // A signal does not end a held worker.
    func terminalResult() async throws -> JITReply {
        if let result { return result }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func finish(_ success: Bool, txm: Bool? = true) {
        workerHasEnded = true
        result = JITReply(operationID: operationID, success: success, message: "finished", txmPresent: txm)
        waiter?.resume(returning: result!); waiter = nil
    }
}
