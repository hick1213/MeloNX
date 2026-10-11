import Foundation

public struct SnapshotVersionGraph {
    private let versions: [UUID: VisibleSnapshot]
    private let unreadable: Set<UUID>
    public init(_ values: [VisibleSnapshot], unreadableGenerations: Set<UUID> = []) throws {
        guard values.count <= 8192, unreadableGenerations.count <= 8192 - values.count else { throw SaveSyncError.malformedSnapshot }
        guard Set(values.map { $0.snapshot.titleID }).count <= 1 else { throw SaveSyncError.malformedSnapshot }
        var map: [UUID: VisibleSnapshot] = [:]
        for value in values {
            try SnapshotValidation.validate(value.snapshot)
            guard map.updateValue(value, forKey: value.snapshot.generation) == nil else { throw SaveSyncError.malformedSnapshot }
        }
        for value in values {
            var seen: Set<UUID> = [value.snapshot.generation]
            var node = value.snapshot
            while let parent = node.parent, let previous = map[parent]?.snapshot {
                guard previous.titleID == node.titleID, previous.ownerUserID == node.ownerUserID,
                      seen.insert(parent).inserted else { throw SaveSyncError.malformedSnapshot }
                node = previous
            }
        }
        self.versions = map; unreadable = unreadableGenerations
    }
    public func select(ownerUserID: String) throws -> CloudHeadSelection {
        guard unreadable.isEmpty else { return .pending(unreadable) }
        let userVersions = versions.values.filter { $0.snapshot.ownerUserID == ownerUserID }
        guard !userVersions.isEmpty else { return .none }
        let parents = Set(userVersions.compactMap { $0.snapshot.parent })
        let heads = userVersions.filter { !parents.contains($0.snapshot.generation) }
        let ids = Set(heads.map { $0.snapshot.generation })
        guard heads.count == 1, let head = heads.first else { return .conflict(ids) }
        switch head.availability { case .pending: return .pending(ids); case .verified: return .ready(head.snapshot.generation) }
    }
}
