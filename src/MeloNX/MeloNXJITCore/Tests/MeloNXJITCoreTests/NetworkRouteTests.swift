import XCTest
@testable import MeloNXJITCore

final class NetworkRouteTests: XCTestCase {
    func testOnlyLocalDevVPNRouteIsAccepted() {
        let cases: [(String, String, Bool)] = [
            ("en0", "10.7.1.1", false), ("utun4", "172.19.0.1", false),
            ("utun4", "10.7.1.1", true), ("ipsec0", "10.7.0.2", true),
            ("utun4", "10.7.invalid.1", false), ("utun4", "10.70.1.1", false),
            ("", "10.7.1.1", false), ("utun4", "10.7.256.1", false)
        ]
        for (interface, address, accepted) in cases {
            XCTAssertEqual(JITNetworkRoute(interface: interface, address: address).isLocalDevVPN, accepted)
        }
    }
}
