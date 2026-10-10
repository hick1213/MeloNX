// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Madeira JITNetwork.swift; see distribution/legal/Madeira-JIT-EXCEPTION.md.
import Darwin
import Foundation
import MeloNXJITCore

nonisolated enum MeloNXLoopbackProbe {
    static let address = "10.7.0.1"
    static let port: UInt16 = 62078

    struct Result {
        let reachable: Bool
        let milliseconds: Double
        let detail: String
    }

    struct Route {
        let interface: String
        let address: String
        /// utun (packet tunnels such as LocalDevVPN), ipsec or ppp.
        var isVPN: Bool { ["utun", "ipsec", "ppp"].contains { interface.hasPrefix($0) } }
        /// Candidate tunnel (not proof of service identity): a VPN interface whose address is in its 10.7.0.0/16.
        var isLocalDevVPN: Bool { JITNetworkRoute(interface: interface, address: address).isLocalDevVPN }
    }

    private static func target() -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        return inet_pton(AF_INET, address, &addr.sin_addr) == 1 ? addr : nil
    }

    private static func connect(_ fd: Int32, _ addr: inout sockaddr_in) -> Int32 {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// The interface and local address traffic to 10.7.0.1 would leave by; nil without a route.
    static func route() -> Route? {
        guard var addr = target() else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, &addr) == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = local.sin_addr
        inet_ntop(AF_INET, &sin, &text, socklen_t(INET_ADDRSTRLEN))
        return Route(interface: interfaceName(holding: local.sin_addr.s_addr) ?? "?", address: String(cString: text))
    }

    private static func interfaceName(holding ip: in_addr_t) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
               sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee.sin_addr.s_addr }) == ip {
                return String(cString: entry.pointee.ifa_name)
            }
            cursor = entry.pointee.ifa_next
        }
        return nil
    }

    /// Blocks for at most `timeout`; use `check(timeout:completion:)` from the main thread.
    /// `requireVPN` is false only for host tests, whose listeners are on lo0.
    static func check(timeout: TimeInterval = 0.4, requireVPN: Bool = true) -> Result {
        let start = CFAbsoluteTimeGetCurrent()
        func done(_ ok: Bool, _ detail: String) -> Result {
            Result(reachable: ok, milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000, detail: detail)
        }
        guard let route = route() else { return done(false, "no route") }
        if requireVPN, !route.isVPN { return done(false, "routed via \(route.interface), not a VPN") }
        if requireVPN, !route.isLocalDevVPN {
            return done(false, "routed via \(route.interface) \(route.address): another VPN, not LocalDevVPN")
        }
        guard var addr = target() else { return done(false, "bad address") }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return done(false, "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        if connect(fd, &addr) != 0 {
            guard errno == EINPROGRESS else { return done(false, String(cString: strerror(errno))) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(max(1, (start + timeout - CFAbsoluteTimeGetCurrent()) * 1000)))
            guard ready > 0 else { return done(false, ready == 0 ? "timed out via \(route.interface)" : String(cString: strerror(errno))) }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return done(false, "\(String(cString: strerror(err))) via \(route.interface)") }
        }
        return done(true, "connected via \(route.interface) \(route.address)")
    }

    static func check(timeout: TimeInterval = 0.4, completion: @escaping @MainActor (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = check(timeout: timeout)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Checks again until the loopback answers or `within` seconds pass: a VPN that
    /// was just connected needs a moment before it routes.
    static func waitUntilReachable(within: TimeInterval, completion: @escaping @MainActor (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = CFAbsoluteTimeGetCurrent() + within
            var result = check(timeout: 0.4)
            while !result.reachable, CFAbsoluteTimeGetCurrent() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                result = check(timeout: 0.4)
            }
            let final = result
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(final) } }
        }
    }

    /// Candidate route is up (authentication is still required): traffic to 10.7.0.1 leaves by its tunnel. Instant: no
    /// network traffic.
    static var vpnInterfaceUp: Bool { route()?.isLocalDevVPN ?? false }
}

nonisolated struct JITNetworkProbe: JITNetworkChecking {
    func check() async -> JITNetworkStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = MeloNXLoopbackProbe.check(timeout: 5)
                continuation.resume(returning: JITNetworkStatus(canAttemptAuthentication: result.reachable, reason: result.reachable ? nil : result.detail))
            }
        }
    }
}
