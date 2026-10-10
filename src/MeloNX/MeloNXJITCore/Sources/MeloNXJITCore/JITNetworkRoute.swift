import Foundation

public struct JITNetworkRoute: Sendable {
    public let interface: String
    public let address: String
    public init(interface: String, address: String) {
        self.interface = interface
        self.address = address
    }
    public var isLocalDevVPN: Bool {
        guard ["utun", "ipsec", "ppp"].contains(where: interface.hasPrefix) else { return false }
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 10 && octets[1] == 7
    }
}
