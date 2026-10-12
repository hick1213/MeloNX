import XCTest
@testable import MeloNXOperationCore
final class AnisotropySelectionTests: XCTestCase {
    func testGameControlledValueRoundTripsThroughSliderZero() {
        XCTAssertEqual(AnisotropySelection.sliderValue(for: -1), 0)
        XCTAssertEqual(AnisotropySelection.nativeValue(for: 0), -1)
    }
    func testInvalidLegacyValuesCannotBecomeForcedAnisotropy() {
        for value: Float in [-1, 0, 0.5, 17, .nan, .infinity] {
            XCTAssertEqual(AnisotropySelection.nativeValue(for: value), -1)
        }
    }
    func testValidUserFilteringIsPreserved() {
        for value: Float in [1, 2, 9.5, 16] {
            XCTAssertEqual(AnisotropySelection.nativeValue(for: value), value)
            XCTAssertEqual(AnisotropySelection.sliderValue(for: value), value)
        }
    }
}
