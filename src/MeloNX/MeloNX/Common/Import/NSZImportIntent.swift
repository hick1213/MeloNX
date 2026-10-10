import Foundation
import UniformTypeIdentifiers

enum NSZImportIntent {
    case library, open, update(applicationID: UInt64), dlc(applicationID: UInt64)
    var kind: Int {
        switch self { case .library, .open: return 0; case .update: return 1; case .dlc: return 2 }
    }
    var applicationID: UInt64? {
        switch self { case .library, .open: return nil; case .update(let id), .dlc(let id): return id }
    }
    var target: URL {
        switch self {
        case .library, .open: return .romsURL
        case .update(let id): return URL.documentsDirectory.appendingPathComponent("updates").appendingPathComponent(String(format: "%016llx", id))
        case .dlc(let id): return URL.documentsDirectory.appendingPathComponent("dlc").appendingPathComponent(String(format: "%016llx", id))
        }
    }
}
extension UTType { static let nsz = UTType(exportedAs: "com.melonx.switch-compressed-package", conformingTo: .data) }
