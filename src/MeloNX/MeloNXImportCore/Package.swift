// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MeloNXImportCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "MeloNXImportCore", targets: ["MeloNXImportCore"])],
    targets: [.target(name: "MeloNXImportCore"),
              .testTarget(name: "MeloNXImportCoreTests", dependencies: ["MeloNXImportCore"])])
