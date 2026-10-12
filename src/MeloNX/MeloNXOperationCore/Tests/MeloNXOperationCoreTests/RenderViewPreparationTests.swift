import XCTest
@testable import MeloNXOperationCore

final class RenderViewPreparationTests: XCTestCase {
    private final class Surface { let id: Int; init(_ id: Int) { self.id = id } }
    func testCachedViewRepublishesLayerBeforeWorkerLaunchWithoutRecreation() {
        let cached = Surface(42)
        var nativeLayer = 0, creations = 0
        let chosen = RenderViewPreparation.prepare(cached: cached, create: { creations += 1; return Surface(99) },
            publish: { nativeLayer = $0.id })
        XCTAssertTrue(chosen === cached)
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(nativeLayer, 42)
    }
    func testFreshViewIsCreatedAndPublishedOnce() {
        var creations = 0, publications = 0
        let chosen = RenderViewPreparation.prepare(cached: Optional<Surface>.none, create: { creations += 1; return Surface(7) },
            publish: { publications += 1; XCTAssertEqual($0.id, 7) })
        XCTAssertEqual(chosen.id, 7)
        XCTAssertEqual(creations, 1); XCTAssertEqual(publications, 1)
    }
}
