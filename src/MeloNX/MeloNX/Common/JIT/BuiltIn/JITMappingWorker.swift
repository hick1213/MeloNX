import Foundation
import Darwin
import MeloNXJITCore

nonisolated final class JITMappingWorker: @unchecked Sendable, JITMapping {
    static let shared = JITMappingWorker()
    private let queue = DispatchQueue(label: "org.melonx.jit.mapping")
    private let lock = NSLock()
    private var publishedReady = false
    private var initialized = false // Accessed only by queue.
    private var probeRX: UnsafeMutableRawPointer?
    private var probeRW: UnsafeMutableRawPointer?
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return publishedReady }
    func publishReady(_ ready: Bool) { lock.lock(); publishedReady = ready; lock.unlock() }
    func initializeExternal(legacy: Bool) async -> Bool {
        if !legacy {
            guard JITDebuggerProbe.snapshot().currentlyTraced == true else { return isReady }
            return (try? await initialize()) ?? false
        }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: testDualMappedExecution()) }
        }
    }
    func initialize() async throws -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !Thread.isMainThread else { continuation.resume(returning: false); return }
                let mapped = JITMappingLifecycle.run(poolReady: self.initialized,
                    createProbe: { self.makeExecutionProbe() },
                    executeProbe: { self.probeRX.map { execute_function_pointer($0) == 42 } ?? false },
                    initializePool: { let result = Ryujinx.initDualMapping(); self.initialized = result; return result },
                    isTraced: { JITDebuggerProbe.snapshot().currentlyTraced },
                    detach: { BreakJITDetach() })
                continuation.resume(returning: mapped)
            }
        }
    }
    private func makeExecutionProbe() -> Bool {
        let size = Int(vm_page_size)
        guard let rx = BreakGetJITMapping(nil, size) else { return false }
        var alias: vm_address_t = 0
        var current: vm_prot_t = 0, maximum: vm_prot_t = 0
        let result = Darwin.vm_remap(mach_task_self_, &alias, vm_size_t(size), 0,
                                    VM_FLAGS_ANYWHERE, mach_task_self_, vm_address_t(UInt(bitPattern: rx)),
                                    0, &current, &maximum, VM_INHERIT_NONE)
        guard result == KERN_SUCCESS,
              Darwin.vm_protect(mach_task_self_, alias, vm_size_t(size), 0, VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS,
              let rw = UnsafeMutableRawPointer(bitPattern: UInt(alias)) else { return false }
        let words: [UInt32] = [0xD2800540, 0xD65F03C0] // mov x0,#42; ret
        words.withUnsafeBytes { rw.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        sys_icache_invalidate(rx, 8)
        probeRX = rx; probeRW = rw // Retained for process-scoped repeat-execution proof.
        return true
    }
}
