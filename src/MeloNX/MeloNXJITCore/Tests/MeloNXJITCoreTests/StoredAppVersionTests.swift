import XCTest
@testable import MeloNXJITCore

final class StoredAppVersionTests: XCTestCase {
    func testFirstLaunchAndMalformedDataUseZero() {
        for data in [Data(), Data([1]), Data(repeating: 0, count: 5)] {
            XCTAssertEqual(StoredAppVersion.decode(data), 0)
        }
    }
    func testStoredFloatAndUnalignedSliceDecodeWithoutTrap() {
        var version: Float = 2.6
        let encoded = withUnsafeBytes(of: &version) { Data($0) }
        XCTAssertEqual(StoredAppVersion.decode(encoded), version)
        var framed = Data([99]); framed.append(encoded); framed.append(99)
        XCTAssertEqual(StoredAppVersion.decode(framed.subdata(in: 1..<5)), version)
        var invalid = Float.nan
        XCTAssertEqual(StoredAppVersion.decode(withUnsafeBytes(of: &invalid) { Data($0) }), 0)
    }
}
