import Foundation

public enum JITTransportError: Error, LocalizedError, Sendable {
    case missingHelper, unavailable, cancelled, interrupted, invalidResponse, cancellationUnavailable
    public var errorDescription: String? {
        switch self {
        case .missingHelper: return "This installation is missing the JIT helper. Keep app extensions when signing MeloNX."
        case .unavailable: return "Built-in JIT requires a physical device on iPadOS 26 or later, outside LiveContainer."
        case .cancelled: return "The JIT helper request was cancelled."
        case .interrupted: return "The JIT helper stopped unexpectedly."
        case .invalidResponse: return "The JIT helper returned an invalid response."
        case .cancellationUnavailable: return "This system cannot cancel the JIT helper. Retry remains disabled until it stops."
        }
    }
}

/// Terminal callback delivery and worker lifetime are separate facts.
public struct JITHelperTerminal {
    public let operationID: UUID
    public private(set) var result: Result<JITReply, Error>?
    public var hasResult: Bool { result != nil }
    public init(operationID: UUID) { self.operationID = operationID }
    @discardableResult public mutating func receive(_ data: Data) throws -> Bool {
        guard result == nil else { return false }
        do {
            result = .success(try JITReply.decode(data, expectedID: operationID))
            return true
        } catch {
            result = .failure(JITTransportError.invalidResponse)
            throw error
        }
    }
    @discardableResult public mutating func fail(_ error: JITTransportError) -> Bool {
        guard result == nil else { return false }
        result = .failure(error)
        return true
    }
    public func canRelease(workerEnded: Bool, traced: Bool?) -> Bool {
        hasResult && workerEnded && traced == false
    }
}

public enum JITHelperLocation {
    public static let file = "MeloNXJITHelper.appex"
    public static func identifier(in plugins: URL?) -> String? {
        guard let plugins else { return nil }
        let infoURL = plugins.appendingPathComponent(file).appendingPathComponent("Info.plist")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: infoURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
              let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              !identifier.isEmpty, identifier.utf8.count <= 255 else { return nil }
        return identifier
    }
}

public enum JITCancellationSignal {
    public static func name(for operationID: UUID) -> String {
        "org.melonx.jit.cancel." + operationID.uuidString
    }
}
public struct JITHelperCapability {
    public let hasOwnedCancellation: Bool
    public init(info: [String: Any]) {
        hasOwnedCancellation = (info["MeloNXJITCancellationVersion"] as? Int) == 2
    }
}

extension JITHelperTerminal {
    /// The actual host completion pipeline. Malformed data always produces a
    /// terminal failure; only a validated reply acknowledges worker completion.
    @discardableResult public mutating func acceptWorkerCompletion(_ data: Data) -> Bool {
        do {
            _ = try JITReply.decode(data, expectedID: operationID)
            _ = try receive(data)
            return true
        } catch {
            fail(.invalidResponse)
            return false
        }
    }
}
