// Combined with the unmodified production ScriptRunner.swift by check-script-runner.sh.
// Only the transport and unrelated script bundle are stubbed; packet generation and
// response handling execute the real production code.
final class OwnedDebugTransport {
    var reply = "OK"
    var replies: [String] = []
    var rawPackets: [[UInt8]] = []
    var commands: [String] = []
    func send(_ command: String) throws -> String { commands.append(command); return reply }
    func sendRaw(_ bytes: ArraySlice<UInt8>) throws { rawPackets.append(Array(bytes)) }
    func readResponse() throws -> String { replies.isEmpty ? reply : replies.removeFirst() }
}
enum StikJIT { struct Script { let name = "test" } }
enum StikJITError: Error { case scriptUnavailable, scriptExecution(String) }
enum BundledScript {
    static func source(for script: StikJIT.Script) throws -> String {
        "prepare_memory_region(0x7000008000, 16384); send_command('must-not-run-after-failure');"
    }
}

extension ScriptRunner {
    static func checkPacketsAndResponses() -> Int {
        var failures = 0
        for address: UInt64 in [0x7000000000, 0x7000008000, 0x701fffffff, 0xffffffffffff8000, 0x1234000] {
            let bytes = makeBlessCommands(startAddress: address, pageCount: 1)
            let packet = String(decoding: bytes, as: UTF8.self)
            let body = packet.split(separator: "#")[0].dropFirst()
            let encoded = body.dropFirst().split(separator: ",")[0]
            if UInt64(encoded, radix: 16) != address {
                print("FAIL: page address truncated: \(String(address, radix: 16)) -> \(encoded)")
                failures += 1
            }
            let checksum = body.utf8.reduce(UInt8(0)) { $0 &+ $1 }
            if packet.suffix(2) != String(format: "%02x", checksum) { failures += 1 }
        }
        let transport = OwnedDebugTransport()
        transport.reply = "E03"
        let runner = ScriptRunner(targetPID: 1, transport: transport, script: .init(), progress: { _ in })
        if runner.prepareMemoryRegion(0x7000008000, length: 0x4000) != nil {
            print("FAIL: rejected page write was reported as successfully prepared")
            failures += 1
        }
        let good = ScriptRunner(targetPID: 1, transport: OwnedDebugTransport(), script: .init(), progress: { _ in })
        if good.prepareMemoryRegion(0x7000008000, length: 0x8000) != "OK" { failures += 1 }
        let batched = OwnedDebugTransport()
        let batchRunner = ScriptRunner(targetPID: 1, transport: batched, script: .init(), progress: { _ in })
        if batchRunner.prepareMemoryRegion(0x7000000000, length: 129 * 16384) != "OK" { failures += 1 }
        if batched.rawPackets.map(\.count) != [3328, 26] { failures += 1 }
        let payload = String(decoding: batched.rawPackets.flatMap { $0 }, as: UTF8.self)
        let frames = payload.split(separator: "$")
        if frames.count != 129 { failures += 1 }
        for (page, frame) in frames.enumerated() {
            let encoded = frame.dropFirst().split(separator: ",")[0]
            if UInt64(encoded, radix: 16) != 0x7000000000 + UInt64(page) * 16384 { failures += 1 }
        }
        let failing = OwnedDebugTransport()
        failing.replies = ["OK", "E03"]
        let failureRunner = ScriptRunner(targetPID: 1, transport: failing, script: .init(), progress: { _ in })
        if failureRunner.prepareMemoryRegion(0x7000000000, length: 129 * 16384) != nil { failures += 1 }
        if failing.rawPackets.count != 1 { failures += 1 }
        let jsTransport = OwnedDebugTransport()
        jsTransport.reply = "E03"
        let jsRunner = ScriptRunner(targetPID: 1, transport: jsTransport, script: .init(), progress: { _ in })
        do { try jsRunner.run(); failures += 1 } catch {}
        if !jsTransport.commands.isEmpty { failures += 1 }
        if failures == 0 { print("PASS: full-width JIT page addresses, checksums and reply validation") }
        return failures
    }
}
exit(ScriptRunner.checkPacketsAndResponses() == 0 ? 0 : 1)
