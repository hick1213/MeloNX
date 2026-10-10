import Foundation
import MeloNXJITCore

nonisolated enum JITDebuggerProbe {
    static func snapshot() -> JITDebuggerSnapshot {
        let traced: Bool?
        switch melonx_jit_tracing_state() { case 0: traced = false; case 1: traced = true; default: traced = nil }
        return .init(codeSigningDebugged: melonx_jit_code_debugged() == 1, currentlyTraced: traced)
    }
}
nonisolated struct SystemJITClock: JITClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 300)) * 1_000_000_000))
    }
}
