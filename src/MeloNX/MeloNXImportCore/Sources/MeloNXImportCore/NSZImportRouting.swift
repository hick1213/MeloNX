import Foundation
public enum NSZImportRouting {
    public static func isNSZ(extension value: String) -> Bool { value.lowercased() == "nsz" }
    public static func accepts(kind: Int, applicationID: UInt64, expectedKind: Int, expectedApplicationID: UInt64?) -> Bool {
        guard (0...2).contains(kind), kind == expectedKind, applicationID != 0 else { return false }
        return expectedApplicationID.map { $0 == applicationID } ?? (kind == 0)
    }
}
