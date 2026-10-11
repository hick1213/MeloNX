import Foundation

/// JSONDecoder handles the grammar and values. This bounded lexical pass also
/// rejects duplicate decoded property names and excessive container nesting.
enum BoundedSaveJSON {
    private struct Frame { let object: Bool; var keys: Set<String> = []; var expectsKey = true }
    static func validate(_ data: Data) throws {
        guard data.count <= SnapshotValidation.maxManifestBytes else { throw SaveSyncError.malformedSnapshot }
        let bytes = Array(data)
        var stack: [Frame] = [], index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123, 91:
                stack.append(Frame(object: bytes[index] == 123))
                guard stack.count <= 64 else { throw SaveSyncError.malformedSnapshot }
            case 125, 93:
                guard !stack.isEmpty else { throw SaveSyncError.malformedSnapshot }
                stack.removeLast()
            case 44:
                if !stack.isEmpty { stack[stack.count - 1].expectsKey = true }
            case 34:
                let start = index; index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw SaveSyncError.malformedSnapshot }
                if let frame = stack.last, frame.object && frame.expectsKey {
                    let name = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard stack[stack.count - 1].keys.insert(name).inserted else { throw SaveSyncError.malformedSnapshot }
                    stack[stack.count - 1].expectsKey = false
                }
            default: break
            }
            index += 1
        }
        guard stack.isEmpty else { throw SaveSyncError.malformedSnapshot }
    }
}
