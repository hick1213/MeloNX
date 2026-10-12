import Foundation
struct CallbackData { let ptr: UnsafeMutableRawPointer?; let len: Int }
enum CallbackManager {
    static var handler: ((CallbackData) -> Void)?
    static func register(name: String, handler: @escaping (CallbackData) -> Void) { self.handler = handler }
}
@main struct StatisticsChecks {
    @MainActor static func main() async {
        let handler = StatisticsHandler(); handler.registerPush()
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: 34, alignment: 8)
        defer { allocation.deallocate() }
        let ptr = allocation.advanced(by: 1)
        ptr.initializeMemory(as: UInt8.self, repeating: 0, count: 33)
        for (offset, value) in [(0, 60.0), (8, 16.7), (17, 77.5)] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { ptr.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: 8) }
        }
        ptr.storeBytes(of: UInt8(1), toByteOffset: 16, as: UInt8.self)
        CallbackManager.handler?(.init(ptr: ptr, len: 33))
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard handler.fps == 60, handler.frameTime == 16.7, handler.fifo == 77.5, handler.started else { exit(1) }
        print("PASS: packed statistics decode from an unaligned payload")
    }
}
