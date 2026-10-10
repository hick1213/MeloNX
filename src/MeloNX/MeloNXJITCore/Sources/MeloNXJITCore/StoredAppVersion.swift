import Foundation

/// First launch has no stored bytes. Data storage does not promise Float alignment.
public enum StoredAppVersion {
    public static func decode(_ data: Data) -> Float {
        guard data.count == MemoryLayout<Float>.size else { return 0 }
        let value = data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        return value.isFinite && value >= 0 ? value : 0
    }
}
