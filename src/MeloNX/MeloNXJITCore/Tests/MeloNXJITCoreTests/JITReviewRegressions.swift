import XCTest
@testable import MeloNXJITCore

final class JITReviewRegressions: XCTestCase {
    func testEveryNewAttachedSessionDetachesEvenWithWarmAllocationCache() {
        var events: [String] = []
        let result = JITMappingLifecycle.run(poolReady: true, createProbe: { XCTFail("must not allocate again"); return false },
            executeProbe: { events.append("execute"); return true }, initializePool: { XCTFail("must not reinitialize pool"); return false },
            isTraced: { true }, detach: { events.append("detach") })
        XCTAssertTrue(result)
        XCTAssertEqual(events, ["execute", "detach"])
    }
    func testFirstNonTXMScriptGetsDetachIndependentOfAllocator() {
        var events: [String] = []
        let result = JITMappingLifecycle.run(poolReady: false, createProbe: { events.append("allocate"); return true },
            executeProbe: { events.append("execute"); return true }, initializePool: { events.append("pool"); return true },
            isTraced: { true }, detach: { events.append("detach") })
        XCTAssertTrue(result)
        XCTAssertEqual(events.last, "detach")
    }
    func testMalformedActualCompletionPipelineStoresTerminalFailure() {
        var terminal = JITHelperTerminal(operationID: UUID())
        XCTAssertFalse(terminal.acceptWorkerCompletion(Data("bad".utf8)))
        XCTAssertTrue(terminal.hasResult)
        XCTAssertFalse(terminal.canRelease(workerEnded: false, traced: false))
    }
    func testProviderSelectionPreservesExistingExternalChoiceAndDynamicSigning() {
        XCTAssertFalse(JITCompatibilityPolicy.useBuiltIn(preference: nil, externalProviderSelected: true))
        XCTAssertTrue(JITCompatibilityPolicy.useBuiltIn(preference: nil, externalProviderSelected: false))
        XCTAssertTrue(JITCompatibilityPolicy.useBuiltIn(preference: true, externalProviderSelected: true))
        XCTAssertFalse(JITCompatibilityPolicy.useBuiltIn(preference: false, externalProviderSelected: false))
        XCTAssertTrue(JITCompatibilityPolicy.useLegacyMapping(dynamicCodeSigning: true, appOnMac: false, majorOS: 27))
    }
}
