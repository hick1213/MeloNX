#if DEBUG
import Foundation

nonisolated private struct NSZProbeManifest: Decodable {
    let version: Int
    let fixtures: [NSZProbeFixture]
}
nonisolated private struct NSZProbeFixture: Decodable { let source: String; let output: String; let sha256: String }
nonisolated private struct NSZNativeProof: Decodable {
    let version: Int
    let passed: Bool
    let sha256: String?
    let cancellationVerified: Bool?
    let spaceFailureVerified: Bool?
}
@MainActor enum NSZImportDiagnostic {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--nsz-conversion-proof") }
    static func runIfRequested() async {
        guard requested else { return }
        let root = URL.documentsDirectory.appendingPathComponent("Downloads/NSZImportQA")
        let result: Result<Bool, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result { try perform(root: root) })
            }
        }
        switch result {
        case .success(let passed):
            AppAlerts.showSyncAlert(title: "NSZ Conversion QA", message: passed ? "Generated conversion vectors and cancellation checks passed. Game import is a separate test." : "Conversion QA failed. See Downloads/NSZImportQA/proof.json.")
        case .failure:
            AppAlerts.showSyncAlert(title: "NSZ Conversion QA", message: "QA fixtures are unavailable or invalid. No game was imported.")
        }
    }
    nonisolated private static func perform(root: URL) throws -> Bool {
        let manifestURL = root.appendingPathComponent("manifest.json")
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 65536 else { throw CocoaError(.fileReadCorruptFile) }
        let manifest = try JSONDecoder().decode(NSZProbeManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, (1...8).contains(manifest.fixtures.count) else { throw CocoaError(.fileReadCorruptFile) }
        var proofs: [[String: Any]] = []
        for fixture in manifest.fixtures {
            guard [fixture.source, fixture.output].allSatisfy({ !$0.contains("/") && !$0.contains("\\") && !$0.contains("..") && !$0.contains("\0") && $0.utf8.count <= 255 }),
                  fixture.source.hasSuffix(".nsz"), fixture.output.hasSuffix(".nsp"), fixture.sha256.count == 64 else { throw CocoaError(.fileReadCorruptFile) }
            let source = root.appendingPathComponent(fixture.source)
            let stem = (fixture.output as NSString).deletingPathExtension
            let output = root.appendingPathComponent("\(stem)-\(UUID().uuidString.lowercased()).nsp")
            let raw = source.path.withCString { source in output.path.withCString { output in nsz_conversion_probe(source, output) } }
            guard let raw else { throw CocoaError(.fileReadCorruptFile) }
            let data = Data(String(cString: raw).utf8); nsz_import_string_free(raw)
            let proof = try JSONDecoder().decode(NSZNativeProof.self, from: data)
            let passed = proof.version == 1 && proof.passed && proof.sha256 == fixture.sha256 && proof.cancellationVerified == true && proof.spaceFailureVerified == true
            proofs.append(["source": fixture.source, "output": output.lastPathComponent, "passed": passed,
                           "sha256": proof.sha256 ?? "", "cancellationVerified": proof.cancellationVerified ?? false,
                           "spaceFailureVerified": proof.spaceFailureVerified ?? false])
        }
        let passed = proofs.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String: Any] = ["version": 1, "passed": passed, "fixtures": proofs,
                                  "syntheticConversionOnly": true, "productionImportVerified": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("proof.json"), options: .atomic)
        return passed
    }
}
#endif
