import Foundation

/// Remote-pairing credentials. Never interpolate this value or its data into logs.
public struct PairingRecord: Sendable {
    public let data: Data

    public init(validating data: Data) throws {
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw JITValidationError.pairingTooLarge
        }
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let fields = value as? [String: Any],
              let publicKey = fields["public_key"] as? Data, publicKey.count == 32,
              let privateKey = fields["private_key"] as? Data, privateKey.count == 32,
              let identifier = fields["identifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identifier.utf8.count <= 256 else {
            throw JITValidationError.invalidPairing
        }
        self.data = data
    }
}
