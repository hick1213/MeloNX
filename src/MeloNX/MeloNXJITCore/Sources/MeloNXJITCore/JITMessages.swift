import Foundation

public enum JITValidationError: Error, LocalizedError {
    case invalidPID, busy, invalidPairing, pairingTooLarge, requestTooLarge
    case unsupportedVersion, missingPairing, unexpectedPayload, replyTooLarge, mismatchedOperation
    public var errorDescription: String? {
        switch self {
        case .invalidPID: return "The JIT target process is invalid."
        case .busy: return "Wait for the previous JIT operation to finish stopping."
        case .invalidPairing: return "Import a valid remote pairing file for this device."
        case .pairingTooLarge: return "The pairing file is empty or too large."
        case .requestTooLarge: return "The JIT request is too large."
        case .unsupportedVersion: return "The JIT helper uses an incompatible protocol version."
        case .missingPairing: return "Pair this device or import a pairing file first."
        case .unexpectedPayload: return "The JIT request contains unexpected fields."
        case .replyTooLarge: return "The JIT helper response is too large."
        case .mismatchedOperation: return "The JIT helper response belongs to a different request."
        }
    }
}

public enum JITOperation: String, Codable, Sendable {
    case prepare, enable, resetDDI
#if DEBUG
    /// Development-only, isolated cancellation proof; no credentials or target allowed.
    case diagnosticWait
#endif
}

public struct JITRequest: Codable, Sendable {
    public static let itemKey = "melonx-jit-request"
    public let version: Int
    public let operationID: UUID
    public let operation: JITOperation
    public let targetPID: Int32?
    public let pairingData: Data?
    public let rsdPort: UInt16?

    public init(version: Int = 1, operationID: UUID, operation: JITOperation,
                targetPID: Int32? = nil, pairingData: Data? = nil, rsdPort: UInt16? = nil) {
        self.version = version
        self.operationID = operationID
        self.operation = operation
        self.targetPID = targetPID
        self.pairingData = pairingData
        self.rsdPort = rsdPort
    }

    public func validated() throws -> JITRequest {
        guard version == 1 else { throw JITValidationError.unsupportedVersion }
        guard try JSONEncoder().encode(self).count <= 1_048_576 else {
            throw JITValidationError.requestTooLarge
        }
        switch operation {
        case .enable:
            guard rsdPort != 0 else { throw JITValidationError.unexpectedPayload }
            guard let pid = targetPID, pid > 0 else { throw JITValidationError.invalidPID }
            guard let pairingData else { throw JITValidationError.missingPairing }
            _ = try PairingRecord(validating: pairingData)
        case .prepare:
            guard rsdPort != 0 else { throw JITValidationError.unexpectedPayload }
            guard targetPID == nil else { throw JITValidationError.unexpectedPayload }
            guard let pairingData else { throw JITValidationError.missingPairing }
            _ = try PairingRecord(validating: pairingData)
#if DEBUG
        case .diagnosticWait:
            guard targetPID == nil, pairingData == nil, rsdPort == nil else { throw JITValidationError.unexpectedPayload }
#endif
        case .resetDDI:
            guard targetPID == nil, pairingData == nil, rsdPort == nil else { throw JITValidationError.unexpectedPayload }
        }
        return self
    }

    public static func decode(_ data: Data) throws -> JITRequest {
        guard data.count <= 1_048_576 else { throw JITValidationError.requestTooLarge }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
}

public struct JITReply: Codable, Sendable {
    public static let itemKey = "melonx-jit-response"
    public let version: Int
    public let operationID: UUID
    public let success: Bool
    public let message: String
    public let txmPresent: Bool?

    public init(version: Int = 1, operationID: UUID, success: Bool,
                message: String, txmPresent: Bool?) {
        self.version = version
        self.operationID = operationID
        self.success = success
        self.message = message
        self.txmPresent = txmPresent
    }

    public static func decode(_ data: Data, expectedID: UUID) throws -> JITReply {
        guard data.count <= 65_536 else { throw JITValidationError.replyTooLarge }
        let reply = try JSONDecoder().decode(Self.self, from: data)
        guard reply.version == 1 else { throw JITValidationError.unsupportedVersion }
        guard reply.operationID == expectedID else { throw JITValidationError.mismatchedOperation }
        return reply
    }
}
