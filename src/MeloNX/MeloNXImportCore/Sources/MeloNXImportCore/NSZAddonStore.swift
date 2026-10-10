import Foundation

public struct NSZDlcEntry: Codable, Sendable {
    public let path: String
    public let titleID: UInt64
    public var enabled: Bool
    public init(path: String, titleID: UInt64, enabled: Bool) { self.path = path; self.titleID = titleID; self.enabled = enabled }
    enum CodingKeys: String, CodingKey { case path; case titleID = "title_id"; case enabled = "is_enabled" }
}
public struct NSZDlcContainer: Codable, Sendable {
    public let path: String
    public let entries: [NSZDlcEntry]
    enum CodingKeys: String, CodingKey { case path; case entries = "dlc_nca_list" }
}

// Registration changes metadata only. It must never copy, rename or remove a normalized package.
public final class NSZAddonStore {
    private let documents: URL
    private let write: (Data, URL) throws -> Void
    public init(documents: URL, write: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }) {
        self.documents = documents.standardizedFileURL; self.write = write
    }
    public func relativePath(_ file: NSZImportedFile, kind: Int, applicationID: UInt64) throws -> String {
        guard NSZImportRouting.accepts(kind: file.kind, applicationID: file.applicationID, expectedKind: kind, expectedApplicationID: applicationID), kind == 1 || kind == 2 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = URL(fileURLWithPath: file.path).standardizedFileURL
        let folder = "\(kind == 1 ? "updates" : "dlc")/\(String(format: "%016llx", applicationID))"
        let expected = documents.appendingPathComponent(folder).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.pathExtension.lowercased() == "nsp", url.deletingLastPathComponent() == expected,
              values.isRegularFile == true, values.isSymbolicLink != true,
              expected.resolvingSymlinksInPath() == expected else { throw CocoaError(.fileReadInvalidFileName) }
        return folder + "/" + url.lastPathComponent
    }
    public func registerUpdate(_ file: NSZImportedFile, applicationID: UInt64, cancelled: Bool = false) throws {
        if cancelled { throw CancellationError() }
        let path = try relativePath(file, kind: 1, applicationID: applicationID)
        let url = configURL(applicationID, name: "updates.json")
        var config: [String: Any] = ["paths": [String](), "selected": ""]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let parsed = try JSONSerialization.jsonObject(with: readConfig(url)) as? [String: Any],
                  parsed["paths"] is [String], parsed["selected"] is String else { throw CocoaError(.fileReadCorruptFile) }
            config = parsed
        }
        var paths = config["paths"] as! [String]
        guard paths.count < 8192 else { throw CocoaError(.fileReadCorruptFile) }
        if !paths.contains(path) { paths.append(path) }
        config["paths"] = paths
        if (config["selected"] as? String)?.isEmpty != false { config["selected"] = path }
        let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(data, url)
    }
    public func registerDLC(_ file: NSZImportedFile, applicationID: UInt64, entries: [NSZDlcEntry], cancelled: Bool = false) throws {
        if cancelled { throw CancellationError() }
        let path = try relativePath(file, kind: 2, applicationID: applicationID)
        guard !entries.isEmpty, entries.count <= 8192, entries.allSatisfy({ !$0.path.isEmpty && $0.titleID != 0 }) else { throw CocoaError(.fileReadCorruptFile) }
        let url = configURL(applicationID, name: "dlc.json")
        var containers: [NSZDlcContainer] = []
        if FileManager.default.fileExists(atPath: url.path) { containers = try JSONDecoder().decode([NSZDlcContainer].self, from: readConfig(url)) }
        guard containers.count < 8192 else { throw CocoaError(.fileReadCorruptFile) }
        if !containers.contains(where: { $0.path == path }) {
            let enable = !containers.contains(where: { $0.entries.contains(where: { $0.enabled }) })
            containers.append(NSZDlcContainer(path: path, entries: entries.map { NSZDlcEntry(path: $0.path, titleID: $0.titleID, enabled: enable) }))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(containers)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(data, url)
    }
    private func configURL(_ applicationID: UInt64, name: String) -> URL {
        documents.appendingPathComponent("games").appendingPathComponent(String(format: "%016llx", applicationID)).appendingPathComponent(name)
    }
    private func readConfig(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard (values.fileSize ?? Int.max) <= 4 * 1024 * 1024, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        return try Data(contentsOf: url)
    }
}
