// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MeloNXJITCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "MeloNXJITCore", targets: ["MeloNXJITCore"])],
    targets: [.target(name: "MeloNXJITCore"),
              .testTarget(name: "MeloNXJITCoreTests", dependencies: ["MeloNXJITCore"])])
