import Foundation

/// Startup, foreground and a waiting game share one process-local acquisition.
@MainActor public final class JITAutomaticRequest {
    private var current: (id: UUID, task: Task<Bool, Never>)?
    public var isRunning: Bool { current != nil }
    public init() {}

    public func run(acquire: @escaping @MainActor () async -> Bool) async -> Bool {
        if let current { return await finish(current) }
        let request = (id: UUID(), task: Task { await acquire() })
        current = request
        return await finish(request)
    }

    public func waitForCurrent() async -> Bool {
        guard let current else { return false }
        return await finish(current)
    }

    private func finish(_ request: (id: UUID, task: Task<Bool, Never>)) async -> Bool {
        let ready = await request.task.value
        if current?.id == request.id { current = nil }
        return ready
    }
}
