// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MeloNXSaveSyncCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "MeloNXSaveSyncCore", targets: ["MeloNXSaveSyncCore"])],
    dependencies: [.package(path: "../MeloNXOperationCore")],
    targets: [.target(name: "MeloNXSaveSyncCore", dependencies: ["MeloNXOperationCore"]),
              .testTarget(name: "MeloNXSaveSyncCoreTests", dependencies: ["MeloNXSaveSyncCore"], resources: [.copy("Fixtures")])])
