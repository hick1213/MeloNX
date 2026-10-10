import Foundation
import Security
import MeloNXJITCore

@MainActor final class JITKeychainPairingStore: JITPairingStoring {
    static let shared = JITKeychainPairingStore()
    private let store: PairingImportStore
    init() { store = PairingImportStore(backend: KeychainPairingBackend()) }
    func load() throws -> PairingRecord? { try store.load() }
    func replace(with data: Data) throws { try store.replace(with: data) }
}

@MainActor private final class KeychainPairingBackend: PairingCredentialBackend {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "MeloNX").built-in-jit.pairing",
         kSecAttrAccount as String: "remote-pairing"]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure(status) }
        var item = query
        item.merge(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure(added) }
    }

    private func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "MeloNXJITPairing", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            "The pairing credential could not be read or saved (\(status)). Unlock this device and try again."])
    }
}
