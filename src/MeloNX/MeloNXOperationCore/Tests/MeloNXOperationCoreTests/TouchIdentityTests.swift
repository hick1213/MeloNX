import XCTest
@testable import MeloNXOperationCore
final class TouchIdentityTests: XCTestCase {
    func testReleasingFirstFingerDoesNotRenumberSecondFinger() {
        var ids = StableTouchIdentifiers<String>()
        XCTAssertEqual(ids.begin("A"), 0); XCTAssertEqual(ids.begin("B"), 1)
        XCTAssertEqual(ids.end("A"), 0)
        XCTAssertEqual(ids.identifier(for: "B"), 1)
        XCTAssertEqual(ids.begin("C"), 2)
        XCTAssertEqual(ids.end("B"), 1)
        XCTAssertEqual(ids.identifier(for: "C"), 2)
    }
    func testDuplicateBeginAndCancelDoNotLeaveStuckTouch() {
        var ids = StableTouchIdentifiers<String>()
        XCTAssertEqual(ids.begin("A"), ids.begin("A"))
        XCTAssertEqual(ids.end("A"), 0); XCTAssertNil(ids.end("A"))
        XCTAssertNil(ids.identifier(for: "A"))
    }
    func testResetReturnsEveryActiveIdentifierToReleaseNativeTouches() {
        var ids = StableTouchIdentifiers<String>()
        _ = ids.begin("A"); _ = ids.begin("B")
        XCTAssertEqual(ids.reset(), [0, 1]); XCTAssertNil(ids.identifier(for: "B"))
        XCTAssertEqual(ids.begin("C"), 0)
    }
}
