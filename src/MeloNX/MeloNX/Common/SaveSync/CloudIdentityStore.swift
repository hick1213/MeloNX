import Foundation
import Security
import MeloNXSaveSyncCore

/// Opaque iCloud tokens stay in this local Keychain item. Cloud documents contain
/// neither the token nor an account identifier; bindings use a random local UUID.
nonisolated final class CloudAccountTokenGuard: @unchecked Sendable {
    private let token: NSObject
    init(_ token: NSObject) { self.token = token }
    func check() throws {
        guard let current = FileManager.default.ubiquityIdentityToken as? NSObject, token.isEqual(current) else { throw SaveSyncError.identityMismatch }
    }
}
actor CloudIdentityStore {
    func capture(_ identity: CloudIdentity) throws -> CloudAccountTokenGuard {
        let value = try self.identity(container: identity.container)
        guard value == identity, let currentToken else { throw SaveSyncError.identityMismatch }
        return CloudAccountTokenGuard(currentToken)
    }
    private struct Entry: Codable { let key: UUID; let token: Data }
    private var currentToken: NSObject?
    private var currentKey: UUID?
    func identity(container: String) throws -> CloudIdentity {
        guard let token = FileManager.default.ubiquityIdentityToken as? NSObject else { throw SaveSyncError.cloudUnavailable }
        if let currentToken, currentToken.isEqual(token), let currentKey {
            return CloudIdentity(localAccountKey: currentKey, container: container)
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.hick.MeloNX.cloud-identity.v1", kSecAttrAccount as String: container]
        var read = query
        read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SaveSyncError.cloudUnavailable }
        var entries: [Entry] = []
        if let data = result as? Data, data.count <= 1024 * 1024 { entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? [] }
        var key: UUID?
        for entry in entries where entry.token.count <= 65536 {
            // NSObject permits Apple's private secure token subclass without
            // interpreting its fields. Corrupt/unrestorable tokens are not reused.
            if let old = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSObject.self], from: entry.token) as? NSObject, old.isEqual(token) {
                key = entry.key; break
            }
        }
        if key == nil {
            key = UUID()
            if let archive = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true), archive.count <= 65536 {
                entries.append(Entry(key: key!, token: archive))
                let data = try JSONEncoder().encode(entries)
                guard data.count <= 1024 * 1024 else { throw SaveSyncError.cloudUnavailable }
                let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                if update == errSecItemNotFound {
                    var add = query; add[kSecValueData as String] = data
                    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw SaveSyncError.cloudUnavailable }
                } else if update != errSecSuccess { throw SaveSyncError.cloudUnavailable }
            }
            // If secure token persistence is unavailable, use a new UUID for
            // this process. Never guess that an old account binding is applicable.
        }
        currentToken = token; currentKey = key
        return CloudIdentity(localAccountKey: key!, container: container)
    }
}
