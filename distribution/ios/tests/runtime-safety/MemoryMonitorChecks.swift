import Foundation
@main struct MemoryMonitorChecks {
    @MainActor static func main() {
        var polls = 0
        weak var released: MemoryUsageMonitor?
        do {
            let monitor = MemoryUsageMonitor(reader: { polls += 1; return UInt64(polls) }, interval: 0.01)
            guard polls == 0 else { exit(1) }
            monitor.start(); monitor.start()
            guard polls == 1 else { exit(1) }
            pump(0.06)
            guard polls > 1 else { print("FAIL: active timer did not sample memory"); exit(1) }
            monitor.stop(); let stopped = polls
            pump(0.06)
            guard polls == stopped else { print("FAIL: stopped timer still sampled memory"); exit(1) }
            monitor.start(); guard polls == stopped + 1 else { exit(1) }
            released = monitor
        }
        guard released == nil else { print("FAIL: active timer retains released monitor"); exit(1) }
        let final = polls; pump(0.06)
        guard polls == final else { print("FAIL: released timer still sampled memory"); exit(1) }
        print("PASS: active monitor release, single start, stop, restart and timer cancellation")
    }
    static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: until) }
    }
}
