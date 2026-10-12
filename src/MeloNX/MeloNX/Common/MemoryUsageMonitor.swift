import Foundation
import Combine

@MainActor
final class MemoryUsageMonitor: ObservableObject {
    @Published private(set) var memoryUsage: UInt64 = 0
    private var timer: AnyCancellable?
    private let reader: () -> UInt64
    private let interval: TimeInterval

    init(reader: (() -> UInt64)? = nil, interval: TimeInterval = 0.2) {
        self.reader = reader ?? Self.readMemoryUsage
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        memoryUsage = reader()
        timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.memoryUsage = self.reader()
            }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private static func readMemoryUsage() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func formatMemorySize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
