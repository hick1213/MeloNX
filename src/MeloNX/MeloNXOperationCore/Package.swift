// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MeloNXOperationCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "MeloNXOperationCore", targets: ["MeloNXOperationCore"])],
    targets: [.target(name: "MeloNXOperationCore"),
              .testTarget(name: "MeloNXOperationCoreTests", dependencies: ["MeloNXOperationCore"])])
